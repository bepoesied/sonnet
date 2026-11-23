defmodule SonnetWeb.API.AuthControllerTest do
  use SonnetWeb.ConnCase, async: true

  alias Sonnet.Accounts

  describe "POST /api/auth/mobile/exchange" do
    test "exchanges a valid PKCE handoff code for Sonnet access and refresh tokens", %{conn: conn} do
      user = user_fixture(%{name: "Mobile User", avatar_url: "https://example.test/avatar.png"})
      {verifier, challenge} = pkce_pair()

      {:ok, code} =
        Accounts.create_mobile_auth_code(user, %{
          code_challenge: challenge,
          redirect_uri: "sonnet://auth/callback"
        })

      conn =
        post(json_conn(conn), ~p"/api/auth/mobile/exchange", %{
          code: code,
          code_verifier: verifier,
          redirect_uri: "sonnet://auth/callback"
        })

      assert get_resp_header(conn, "cache-control") == ["no-store"]
      assert get_resp_header(conn, "pragma") == ["no-cache"]

      payload = json_response(conn, 200)
      assert is_binary(payload["access_token"])
      assert is_binary(payload["refresh_token"])
      assert payload["user"]["id"] == user.id
      assert payload["user"]["name"] == "Mobile User"
      assert payload["user"]["avatar_url"] == "https://example.test/avatar.png"

      assert {:ok, access_token} = Base.url_decode64(payload["access_token"], padding: false)
      assert {:ok, refresh_token} = Base.url_decode64(payload["refresh_token"], padding: false)

      assert {%Accounts.User{id: user_id}, _inserted_at} =
               Accounts.get_user_by_session_token(access_token)

      assert user_id == user.id

      assert {%Accounts.User{id: ^user_id}, _inserted_at} =
               Accounts.get_user_by_refresh_token(refresh_token)

      # Replaying the same handoff code must fail
      replay_conn =
        post(json_conn(build_conn()), ~p"/api/auth/mobile/exchange", %{
          code: code,
          code_verifier: verifier,
          redirect_uri: "sonnet://auth/callback"
        })

      assert json_response(replay_conn, 401) == %{"error" => "invalid_grant"}
    end

    test "returns 400 when required fields are missing or non-string", %{conn: conn} do
      for body <- [
            %{},
            %{code: "abc"},
            %{code: "abc", code_verifier: "def"},
            %{code: 123, code_verifier: "def", redirect_uri: "sonnet://auth/callback"}
          ] do
        resp = post(json_conn(build_conn()), ~p"/api/auth/mobile/exchange", body)
        assert json_response(resp, 400) == %{"error" => "invalid_request"}
        assert get_resp_header(resp, "cache-control") == ["no-store"]
      end

      _ = conn
    end

    test "returns 401 invalid_grant and burns the code on PKCE verifier mismatch", %{conn: conn} do
      user = user_fixture()
      {verifier, challenge} = pkce_pair()
      {wrong_verifier, _} = pkce_pair()

      {:ok, code} =
        Accounts.create_mobile_auth_code(user, %{
          code_challenge: challenge,
          redirect_uri: "sonnet://auth/callback"
        })

      bad_conn =
        post(json_conn(conn), ~p"/api/auth/mobile/exchange", %{
          code: code,
          code_verifier: wrong_verifier,
          redirect_uri: "sonnet://auth/callback"
        })

      assert json_response(bad_conn, 401) == %{"error" => "invalid_grant"}

      retry_conn =
        post(json_conn(build_conn()), ~p"/api/auth/mobile/exchange", %{
          code: code,
          code_verifier: verifier,
          redirect_uri: "sonnet://auth/callback"
        })

      assert json_response(retry_conn, 401) == %{"error" => "invalid_grant"}
    end

    test "returns 401 invalid_grant and burns the code on redirect_uri mismatch", %{conn: conn} do
      user = user_fixture()
      {verifier, challenge} = pkce_pair()

      {:ok, code} =
        Accounts.create_mobile_auth_code(user, %{
          code_challenge: challenge,
          redirect_uri: "sonnet://auth/callback"
        })

      bad_conn =
        post(json_conn(conn), ~p"/api/auth/mobile/exchange", %{
          code: code,
          code_verifier: verifier,
          redirect_uri: "sonnet://other/callback"
        })

      assert json_response(bad_conn, 401) == %{"error" => "invalid_grant"}

      retry_conn =
        post(json_conn(build_conn()), ~p"/api/auth/mobile/exchange", %{
          code: code,
          code_verifier: verifier,
          redirect_uri: "sonnet://auth/callback"
        })

      assert json_response(retry_conn, 401) == %{"error" => "invalid_grant"}
    end

    test "returns 401 invalid_grant for expired codes", %{conn: conn} do
      user = user_fixture()
      {verifier, challenge} = pkce_pair()

      {:ok, code} =
        Accounts.create_mobile_auth_code(
          user,
          %{code_challenge: challenge, redirect_uri: "sonnet://auth/callback"},
          signed_at: System.system_time(:second) - 120
        )

      resp =
        post(json_conn(conn), ~p"/api/auth/mobile/exchange", %{
          code: code,
          code_verifier: verifier,
          redirect_uri: "sonnet://auth/callback"
        })

      assert json_response(resp, 401) == %{"error" => "invalid_grant"}
    end
  end

  describe "POST /api/auth/token-refresh" do
    test "atomically rotates a refresh token on the API auth route", %{conn: conn} do
      user = user_fixture()
      refresh_token = Accounts.generate_user_refresh_token(user)

      conn =
        post(json_conn(conn), ~p"/api/auth/token-refresh", %{
          refresh_token: Base.url_encode64(refresh_token, padding: false)
        })

      assert get_resp_header(conn, "cache-control") == ["no-store"]
      payload = json_response(conn, 200)
      assert is_binary(payload["access_token"])
      assert is_binary(payload["refresh_token"])

      assert {:ok, access_token} = Base.url_decode64(payload["access_token"], padding: false)

      assert {:ok, new_refresh_token} =
               Base.url_decode64(payload["refresh_token"], padding: false)

      assert {%Accounts.User{id: user_id}, _inserted_at} =
               Accounts.get_user_by_session_token(access_token)

      assert user_id == user.id

      assert {%Accounts.User{id: ^user_id}, _inserted_at} =
               Accounts.get_user_by_refresh_token(new_refresh_token)

      refute Accounts.get_user_by_refresh_token(refresh_token)
    end
  end

  describe "POST /api/auth/logout" do
    test "deletes submitted access and refresh tokens on the API auth route", %{conn: conn} do
      user = user_fixture()
      access_token = Accounts.generate_user_session_token(user)
      refresh_token = Accounts.generate_user_refresh_token(user)

      conn =
        conn
        |> json_conn()
        |> put_req_header(
          "authorization",
          "Bearer #{Base.url_encode64(access_token, padding: false)}"
        )
        |> post(~p"/api/auth/logout", %{
          refresh_token: Base.url_encode64(refresh_token, padding: false)
        })

      assert json_response(conn, 200) == %{"ok" => true}
      refute Accounts.get_user_by_session_token(access_token)
      refute Accounts.get_user_by_refresh_token(refresh_token)
    end
  end

  describe "removed legacy API auth routes" do
    test "does not route /api/mobile-config", %{conn: conn} do
      conn = get(json_conn(conn), "/api/mobile-config")
      assert response(conn, 404)
    end

    test "does not route /api/auth/oidc-login", %{conn: conn} do
      conn = post(json_conn(conn), "/api/auth/oidc-login", %{})
      assert response(conn, 404)
    end

    test "does not route the legacy token refresh alias", %{conn: conn} do
      conn = post(json_conn(conn), "/users/token-refresh", %{})
      assert response(conn, 404)
    end

    test "does not route the legacy logout alias", %{conn: conn} do
      conn = post(json_conn(conn), "/users/logout", %{})
      assert response(conn, 404)
    end
  end

  defp json_conn(conn) do
    put_req_header(conn, "accept", "application/json")
  end

  defp user_fixture(overrides \\ %{}) do
    attrs =
      Map.merge(
        %{sub: Ecto.UUID.generate(), name: "Test User"},
        overrides
      )

    {:ok, user} = Accounts.register_user(attrs)
    user
  end

  defp pkce_pair do
    verifier = 48 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
    {verifier, challenge}
  end
end
