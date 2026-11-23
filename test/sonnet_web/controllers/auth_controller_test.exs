defmodule SonnetWeb.AuthControllerTest do
  use SonnetWeb.ConnCase, async: true

  import Ecto.Query

  alias Oidcc.Plug.AuthorizationCallback
  alias Oidcc.Plug.Authorize
  alias Sonnet.Accounts
  alias Sonnet.Accounts.UserToken
  alias Sonnet.Repo
  alias SonnetWeb.AuthController

  defp pkce_pair do
    verifier = 48 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
    {verifier, challenge}
  end

  defp valid_state do
    24 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  defp mobile_code_rows do
    Repo.all(from t in UserToken, where: t.context == "mobile_code")
  end

  defp base_callback_conn(conn, session \\ %{}) do
    conn
    |> Map.replace!(:secret_key_base, SonnetWeb.Endpoint.config(:secret_key_base))
    |> fetch_query_params()
    |> Phoenix.Controller.put_format("html")
    |> Phoenix.Controller.put_view(html: SonnetWeb.AuthHTML)
    |> init_test_session(session)
    |> fetch_flash()
    |> assign(:current_scope, nil)
  end

  describe "web OIDC callback" do
    test "upserts user and starts a local session", %{conn: conn} do
      sub = "oidc-web-#{System.unique_integer([:positive])}"

      conn =
        conn
        |> base_callback_conn()
        |> put_private(
          AuthorizationCallback,
          {:ok,
           {:token,
            %{
              "sub" => sub,
              "name" => "OIDC Web User",
              "picture" => "https://example.test/avatar.png"
            }}}
        )
        |> AuthController.callback(%{})

      assert redirected_to(conn) == ~p"/"
      assert get_resp_header(conn, "cache-control") == ["no-store"]
      assert token = get_session(conn, :user_token)

      assert {%Accounts.User{sub: ^sub, name: "OIDC Web User"}, _inserted_at} =
               Accounts.get_user_by_session_token(token)
    end

    test "renders an error page on provider failure without leaking internals", %{conn: conn} do
      conn =
        conn
        |> base_callback_conn()
        |> put_private(AuthorizationCallback, {:error, {:secret_internal_reason, "token"}})
        |> AuthController.callback(%{})

      assert html_response(conn, 400) =~ "Sign-in failed"
      refute html_response(conn, 400) =~ "secret_internal_reason"
      refute get_session(conn, :user_token)
    end
  end

  describe "DELETE /auth/logout" do
    test "clears the local session and revokes the DB session token", %{conn: conn} do
      {:ok, user} = Accounts.register_user(%{sub: Ecto.UUID.generate(), name: "Logout User"})
      token = Accounts.generate_user_session_token(user)

      conn =
        conn
        |> init_test_session(user_token: token)
        |> delete(~p"/auth/logout")

      assert redirected_to(conn) == ~p"/"
      refute get_session(conn, :user_token)
      refute Accounts.get_user_by_session_token(token)
    end
  end

  describe "GET /auth/mobile/authorize validation" do
    test "rejects disallowed redirect_uri attempts before touching OIDC provider", %{conn: conn} do
      {_verifier, challenge} = pkce_pair()

      for bad_uri <- [
            "https://evil.example/steal",
            "sonnet://auth/callback/extra",
            "sonnet://auth/callback?foo=bar",
            "sonnet://auth/callback#frag",
            "javascript:alert(1)"
          ] do
        resp =
          get(build_conn(), ~p"/auth/mobile/authorize", %{
            "redirect_uri" => bad_uri,
            "code_challenge" => challenge,
            "code_challenge_method" => "S256",
            "state" => valid_state()
          })

        assert html_response(resp, 400) =~ "Sign-in failed"
        assert get_resp_header(resp, "cache-control") == ["no-store"]
        refute get_session(resp, :mobile_auth)
      end

      _ = conn
    end

    test "rejects plain PKCE method before touching OIDC provider", %{conn: conn} do
      {_verifier, challenge} = pkce_pair()

      conn =
        get(conn, ~p"/auth/mobile/authorize", %{
          "redirect_uri" => "sonnet://auth/callback",
          "code_challenge" => challenge,
          "code_challenge_method" => "plain",
          "state" => valid_state()
        })

      assert html_response(conn, 400) =~ "S256"
      refute get_session(conn, :mobile_auth)
    end

    test "rejects malformed code_challenge before touching OIDC provider", %{conn: conn} do
      conn =
        get(conn, ~p"/auth/mobile/authorize", %{
          "redirect_uri" => "sonnet://auth/callback",
          "code_challenge" => "too-short",
          "code_challenge_method" => "S256",
          "state" => valid_state()
        })

      assert html_response(conn, 400) =~ "challenge"
      refute get_session(conn, :mobile_auth)
    end

    test "rejects missing or weak state before touching OIDC provider", %{conn: conn} do
      {_verifier, challenge} = pkce_pair()

      conn =
        get(conn, ~p"/auth/mobile/authorize", %{
          "redirect_uri" => "sonnet://auth/callback",
          "code_challenge" => challenge,
          "code_challenge_method" => "S256",
          "state" => "too-short"
        })

      assert html_response(conn, 400) =~ "state"
      refute get_session(conn, :mobile_auth)
    end
  end

  describe "mobile OIDC callback handoff" do
    test "issues one-time PKCE code, sets no-store/no-referrer, and leaves no web session", %{
      conn: conn
    } do
      sub = "oidc-mobile-#{System.unique_integer([:positive])}"
      {verifier, challenge} = pkce_pair()
      mobile_state = valid_state()
      flow_id = "flow-#{System.unique_integer([:positive])}"

      mobile_session = %{
        "flow_id" => flow_id,
        "redirect_uri" => "sonnet://auth/callback",
        "code_challenge" => challenge,
        "state" => mobile_state
      }

      conn =
        conn
        |> base_callback_conn(%{mobile_auth: mobile_session})
        |> put_private(Authorize.State, "mobile:" <> flow_id)
        |> put_private(
          AuthorizationCallback,
          {:ok,
           {:token,
            %{
              "sub" => sub,
              "name" => "Mobile Handoff User",
              "picture" => "https://example.test/mobile.png"
            }}}
        )
        |> AuthController.callback(%{})

      location = redirected_to(conn, 302)
      assert get_resp_header(conn, "cache-control") == ["no-store"]
      assert get_resp_header(conn, "pragma") == ["no-cache"]
      assert get_resp_header(conn, "referrer-policy") == ["no-referrer"]

      # Must NOT create a web session or keep mobile_auth in session
      refute get_session(conn, :user_token)
      refute get_session(conn, :mobile_auth)
      refute Map.has_key?(conn.resp_cookies, "_sonnet_web_user_remember_me")

      uri = URI.parse(location)
      assert uri.scheme == "sonnet"
      assert uri.host == "auth"
      assert uri.path == "/callback"

      query = URI.decode_query(uri.query)
      assert query["state"] == mobile_state
      assert is_binary(query["code"])

      # End-to-end: exchange the handoff code via the API endpoint
      exchange_conn =
        build_conn()
        |> put_req_header("accept", "application/json")
        |> post(~p"/api/auth/mobile/exchange", %{
          code: query["code"],
          code_verifier: verifier,
          redirect_uri: "sonnet://auth/callback"
        })

      payload = json_response(exchange_conn, 200)
      assert is_binary(payload["access_token"])
      assert is_binary(payload["refresh_token"])
      assert payload["user"]["name"] == "Mobile Handoff User"
      assert payload["user"]["avatar_url"] == "https://example.test/mobile.png"
    end

    test "redirects back to mobile app with generic error when OIDC fails", %{conn: conn} do
      {_verifier, challenge} = pkce_pair()
      mobile_state = valid_state()
      flow_id = "flow-err-#{System.unique_integer([:positive])}"

      mobile_session = %{
        "flow_id" => flow_id,
        "redirect_uri" => "sonnet://auth/callback",
        "code_challenge" => challenge,
        "state" => mobile_state
      }

      conn =
        conn
        |> base_callback_conn(%{mobile_auth: mobile_session})
        |> put_private(Authorize.State, "mobile:" <> flow_id)
        |> put_private(AuthorizationCallback, {:error, :access_denied})
        |> AuthController.callback(%{})

      location = redirected_to(conn, 302)
      query = location |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

      assert query["error"] == "authentication_failed"
      assert query["state"] == mobile_state
      refute Map.has_key?(query, "code")
      refute get_session(conn, :user_token)
      assert mobile_code_rows() == []
    end

    test "rejects flow state mismatches and never falls back to web login", %{conn: conn} do
      {_verifier, challenge} = pkce_pair()
      sub = "oidc-mismatch-#{System.unique_integer([:positive])}"

      userinfo_result = {:ok, {:token, %{"sub" => sub, "name" => "Victim"}}}

      # Case 1: mobile state present in OIDC callback, but no mobile_auth in session
      conn1 =
        conn
        |> base_callback_conn()
        |> put_private(Authorize.State, "mobile:some-flow-id")
        |> put_private(AuthorizationCallback, userinfo_result)
        |> AuthController.callback(%{})

      assert html_response(conn1, 400) =~ "Sign-in failed"
      refute get_session(conn1, :user_token)
      assert mobile_code_rows() == []

      # Case 2: mobile_auth in session, but mismatched flow_id in OIDC state
      conn2 =
        build_conn()
        |> base_callback_conn(%{
          mobile_auth: %{
            "flow_id" => "expected-flow",
            "redirect_uri" => "sonnet://auth/callback",
            "code_challenge" => challenge,
            "state" => valid_state()
          }
        })
        |> put_private(Authorize.State, "mobile:wrong-flow")
        |> put_private(AuthorizationCallback, userinfo_result)
        |> AuthController.callback(%{})

      assert html_response(conn2, 400) =~ "Sign-in failed"
      refute get_session(conn2, :user_token)
      assert mobile_code_rows() == []

      # Case 3: mobile_auth in session, but nil OIDC state
      conn3 =
        build_conn()
        |> base_callback_conn(%{
          mobile_auth: %{
            "flow_id" => "expected-flow",
            "redirect_uri" => "sonnet://auth/callback",
            "code_challenge" => challenge,
            "state" => valid_state()
          }
        })
        |> put_private(AuthorizationCallback, userinfo_result)
        |> AuthController.callback(%{})

      assert html_response(conn3, 400) =~ "Sign-in failed"
      refute get_session(conn3, :user_token)
      assert mobile_code_rows() == []

      # Case 4: non-allowlisted redirect_uri in session
      conn4 =
        build_conn()
        |> base_callback_conn(%{
          mobile_auth: %{
            "flow_id" => "expected-flow",
            "redirect_uri" => "https://evil.example/steal",
            "code_challenge" => challenge,
            "state" => valid_state()
          }
        })
        |> put_private(Authorize.State, "mobile:expected-flow")
        |> put_private(AuthorizationCallback, userinfo_result)
        |> AuthController.callback(%{})

      assert html_response(conn4, 400) =~ "Sign-in failed"
      refute get_session(conn4, :user_token)
      assert mobile_code_rows() == []
    end
  end

  describe "removed legacy Ueberauth routes" do
    test "does not route /auth/oidc", %{conn: conn} do
      conn = get(conn, "/auth/oidc")
      assert response(conn, 404)
    end
  end
end
