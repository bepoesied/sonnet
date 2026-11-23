defmodule SonnetWeb.API.AuthController do
  use SonnetWeb, :controller

  alias Sonnet.Accounts
  alias SonnetWeb.UserSessionController

  def mobile_exchange(conn, %{
        "code" => code,
        "code_verifier" => code_verifier,
        "redirect_uri" => redirect_uri
      })
      when is_binary(code) and is_binary(code_verifier) and is_binary(redirect_uri) do
    conn = put_no_store_headers(conn)

    case Accounts.consume_mobile_auth_code(code, code_verifier, redirect_uri) do
      {:ok, user} ->
        access_token = Accounts.generate_user_session_token(user)
        refresh_token = Accounts.generate_user_refresh_token(user)

        json(conn, %{
          access_token: Base.url_encode64(access_token, padding: false),
          refresh_token: Base.url_encode64(refresh_token, padding: false),
          user: %{
            id: user.id,
            name: user.name,
            avatar_url: user.avatar_url
          }
        })

      {:error, :invalid_grant} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "invalid_grant"})
    end
  end

  def mobile_exchange(conn, _params) do
    conn
    |> put_no_store_headers()
    |> put_status(:bad_request)
    |> json(%{error: "invalid_request"})
  end

  def refresh(conn, params), do: UserSessionController.refresh(conn, params)

  def delete(conn, params), do: UserSessionController.delete(conn, params)

  defp put_no_store_headers(conn) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("pragma", "no-cache")
  end
end
