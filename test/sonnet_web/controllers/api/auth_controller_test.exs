defmodule SonnetWeb.API.AuthControllerTest do
  use SonnetWeb.ConnCase, async: false

  alias Sonnet.Accounts

  setup do
    original_config = Application.get_env(:sonnet, :mobile_oidc)
    jwk = JOSE.JWK.generate_key({:rsa, 2048})
    {_public_fields, public_jwk} = JOSE.JWK.to_public(jwk) |> JOSE.JWK.to_map()
    public_jwk = Map.put(public_jwk, "kid", "test-key")
    client_context = client_context(public_jwk)

    Application.put_env(:sonnet, :mobile_oidc,
      client_id: "mobile-client",
      client_context: client_context
    )

    on_exit(fn ->
      if original_config do
        Application.put_env(:sonnet, :mobile_oidc, original_config)
      else
        Application.delete_env(:sonnet, :mobile_oidc)
      end
    end)

    {:ok, jwk: jwk}
  end

  describe "POST /api/auth/oidc-login" do
    test "upserts a user and returns Sonnet tokens for a valid ID token", %{conn: conn, jwk: jwk} do
      id_token =
        id_token(jwk, %{
          "sub" => "oidc-sub",
          "name" => "Mobile User",
          "picture" => "https://example.test/avatar.png"
        })

      conn = post(json_conn(conn), ~p"/api/auth/oidc-login", %{id_token: id_token})

      payload = json_response(conn, 200)
      assert is_binary(payload["access_token"])
      assert is_binary(payload["refresh_token"])
      assert payload["user"]["name"] == "Mobile User"
      assert payload["user"]["avatar_url"] == "https://example.test/avatar.png"

      assert {:ok, access_token} = Base.url_decode64(payload["access_token"], padding: false)
      assert {:ok, refresh_token} = Base.url_decode64(payload["refresh_token"], padding: false)

      assert {%Accounts.User{sub: "oidc-sub"}, _inserted_at} =
               Accounts.get_user_by_session_token(access_token)

      assert {%Accounts.User{sub: "oidc-sub"}, _inserted_at} =
               Accounts.get_user_by_refresh_token(refresh_token)

      updated_token = id_token(jwk, %{"sub" => "oidc-sub", "name" => "Updated User"})

      updated_conn =
        post(json_conn(build_conn()), ~p"/api/auth/oidc-login", %{id_token: updated_token})

      assert json_response(updated_conn, 200)["user"]["id"] == payload["user"]["id"]
      assert Accounts.get_user_by_sub("oidc-sub").name == "Updated User"
    end

    test "returns a consistent error when the token is missing", %{conn: conn} do
      conn = post(json_conn(conn), ~p"/api/auth/oidc-login", %{})

      assert json_response(conn, 400) == %{"error" => "missing_token"}
    end

    test "returns a consistent error when the token is malformed", %{conn: conn} do
      conn = post(json_conn(conn), ~p"/api/auth/oidc-login", %{id_token: "not-a-jwt"})

      assert json_response(conn, 400) == %{"error" => "malformed_token"}
    end

    test "returns a consistent error when the issuer is invalid", %{conn: conn, jwk: jwk} do
      id_token = id_token(jwk, %{"iss" => "https://wrong.example"})

      conn = post(json_conn(conn), ~p"/api/auth/oidc-login", %{id_token: id_token})

      assert json_response(conn, 401) == %{"error" => "invalid_issuer"}
    end

    test "returns a consistent error when the audience is invalid", %{conn: conn, jwk: jwk} do
      id_token = id_token(jwk, %{"aud" => "wrong-client"})

      conn = post(json_conn(conn), ~p"/api/auth/oidc-login", %{id_token: id_token})

      assert json_response(conn, 401) == %{"error" => "invalid_audience"}
    end

    test "returns a consistent error when the token is expired", %{conn: conn, jwk: jwk} do
      id_token = id_token(jwk, %{"exp" => System.system_time(:second) - 1})

      conn = post(json_conn(conn), ~p"/api/auth/oidc-login", %{id_token: id_token})

      assert json_response(conn, 401) == %{"error" => "expired_token"}
    end

    test "returns a consistent error when the signature is invalid", %{conn: conn} do
      other_jwk = JOSE.JWK.generate_key({:rsa, 2048})
      id_token = id_token(other_jwk, %{"sub" => "oidc-sub"})

      conn = post(json_conn(conn), ~p"/api/auth/oidc-login", %{id_token: id_token})

      assert json_response(conn, 401) == %{"error" => "invalid_signature"}
    end

    test "returns a consistent error when the subject is missing", %{conn: conn, jwk: jwk} do
      id_token = id_token(jwk, %{"sub" => nil})

      conn = post(json_conn(conn), ~p"/api/auth/oidc-login", %{id_token: id_token})

      assert json_response(conn, 401) == %{"error" => "missing_subject"}
    end
  end

  describe "GET /api/mobile-config" do
    test "returns OIDC discovery info for the mobile client", %{conn: conn} do
      conn = get(json_conn(conn), ~p"/api/mobile-config")

      assert json_response(conn, 200) == %{
               "issuer" => "https://issuer.example",
               "client_id" => "mobile-client",
               "authorization_endpoint" => "https://issuer.example/authorize",
               "token_endpoint" => nil,
               "end_session_endpoint" => nil,
               "scopes" => ["openid", "profile"],
               "response_type" => "code",
               "code_challenge_methods_supported" => nil
             }
    end
  end

  describe "POST /api/auth/token-refresh" do
    test "rotates a refresh token on the API auth route", %{conn: conn} do
      user = user_fixture()
      refresh_token = Accounts.generate_user_refresh_token(user)

      conn =
        post(json_conn(conn), ~p"/api/auth/token-refresh", %{
          refresh_token: Base.url_encode64(refresh_token, padding: false)
        })

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

  describe "removed API auth aliases" do
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

  defp user_fixture do
    {:ok, user} = Accounts.register_user(%{sub: Ecto.UUID.generate(), name: "Test User"})
    user
  end

  defp id_token(jwk, overrides) do
    claims =
      Map.merge(
        %{
          "iss" => "https://issuer.example",
          "aud" => "mobile-client",
          "sub" => "mobile-sub",
          "exp" => System.system_time(:second) + 300,
          "iat" => System.system_time(:second),
          "name" => "Mobile User"
        },
        overrides
      )

    jwk
    |> JOSE.JWT.sign(%{"alg" => "RS256", "kid" => "test-key"}, claims)
    |> JOSE.JWS.compact()
    |> elem(1)
  end

  defp client_context(public_jwk) do
    {:ok, provider_configuration} =
      Oidcc.ProviderConfiguration.decode_configuration(%{
        "issuer" => "https://issuer.example",
        "authorization_endpoint" => "https://issuer.example/authorize",
        "jwks_uri" => "https://issuer.example/jwks",
        "scopes_supported" => ["openid", "profile", "email"],
        "response_types_supported" => ["code"],
        "response_modes_supported" => ["query"],
        "grant_types_supported" => ["authorization_code"],
        "subject_types_supported" => ["public"],
        "id_token_signing_alg_values_supported" => ["RS256"],
        "token_endpoint_auth_methods_supported" => ["none"]
      })

    Oidcc.ClientContext.from_manual(
      provider_configuration,
      JOSE.JWK.from_map(%{"keys" => [public_jwk]}),
      "mobile-client",
      :unauthenticated,
      %{}
    )
  end
end
