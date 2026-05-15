defmodule SonnetWeb.API.MeControllerTest do
  use SonnetWeb.ConnCase, async: true

  alias Sonnet.Accounts

  describe "GET /api/me" do
    test "returns the authenticated user", %{conn: conn} do
      user = user_fixture(%{name: "Mobile User", avatar_url: "https://example.test/avatar.png"})
      token = Accounts.generate_user_session_token(user)

      conn =
        conn
        |> authenticated_conn(token)
        |> get(~p"/api/me")

      assert json_response(conn, 200) == %{
               "id" => user.id,
               "name" => "Mobile User",
               "avatar_url" => "https://example.test/avatar.png"
             }
    end

    test "returns JSON 401 when the bearer token is missing", %{conn: conn} do
      conn =
        conn
        |> json_conn()
        |> get(~p"/api/me")

      assert json_response(conn, 401) == %{"error" => "Unauthorized"}
    end

    test "returns JSON 401 when the bearer token is invalid", %{conn: conn} do
      conn =
        conn
        |> json_conn()
        |> put_req_header("authorization", "Bearer invalid-token")
        |> get(~p"/api/me")

      assert json_response(conn, 401) == %{"error" => "Unauthorized"}
    end
  end

  defp authenticated_conn(conn, token) do
    conn
    |> json_conn()
    |> put_req_header("authorization", "Bearer #{Base.url_encode64(token, padding: false)}")
  end

  defp json_conn(conn) do
    put_req_header(conn, "accept", "application/json")
  end

  defp user_fixture(attrs) do
    attrs = Map.merge(%{sub: Ecto.UUID.generate(), name: "Test User"}, attrs)
    {:ok, user} = Accounts.register_user(attrs)
    user
  end
end
