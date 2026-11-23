defmodule SonnetWeb.UserSessionController do
  use SonnetWeb, :controller

  alias Sonnet.Accounts

  def refresh(conn, %{"refresh_token" => refresh_token}) when is_binary(refresh_token) do
    conn =
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header("pragma", "no-cache")

    with {:ok, decoded_token} <- Base.url_decode64(refresh_token, padding: false),
         {:ok, {new_access_token, new_refresh_token}} <-
           Accounts.rotate_user_refresh_token(decoded_token) do
      json(conn, %{
        access_token: Base.url_encode64(new_access_token, padding: false),
        refresh_token: Base.url_encode64(new_refresh_token, padding: false)
      })
    else
      _ ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Invalid or expired refresh token"})
    end
  end

  def refresh(conn, _params) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("pragma", "no-cache")
    |> put_status(:unprocessable_entity)
    |> json(%{error: "Invalid or expired refresh token"})
  end

  def delete(conn, %{"refresh_token" => refresh_token}) when is_binary(refresh_token) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> encoded_access_token] ->
        with {:ok, decoded_access_token} <-
               Base.url_decode64(encoded_access_token, padding: false),
             {:ok, decoded_refresh_token} <- Base.url_decode64(refresh_token, padding: false) do
          Accounts.delete_user_session_token(decoded_access_token)
          Accounts.delete_user_refresh_token(decoded_refresh_token)
          json(conn, %{ok: true})
        else
          :error ->
            conn
            |> put_status(:unauthorized)
            |> json(%{error: "Invalid token format"})
        end

      _ ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "Missing authorization header"})
    end
  end

  def delete(conn, _params) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> encoded_token] ->
        case Base.url_decode64(encoded_token, padding: false) do
          {:ok, decoded_token} ->
            Accounts.delete_user_session_token(decoded_token)
            json(conn, %{ok: true})

          :error ->
            conn
            |> put_status(:unauthorized)
            |> json(%{error: "Invalid authorization header"})
        end

      _ ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "Missing authorization header"})
    end
  end
end
