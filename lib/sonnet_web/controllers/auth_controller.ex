defmodule SonnetWeb.AuthController do
  alias SonnetWeb.UserAuth
  alias Sonnet.Accounts
  use SonnetWeb, :controller

  plug Ueberauth

  def callback(%{assigns: %{ueberauth_auth: auth}} = conn, %{
        "provider" => "oidc",
        "mobile" => "true",
        "redirect_uri" => redirect_uri
      }) do
    case Accounts.register_user(%{
           sub: auth.uid,
           name: auth.info.name,
           avatar_url: auth.info.image
         }) do
      {:ok, user} ->
        handle_mobile_callback(conn, user, redirect_uri)

      {:error, _changeset} ->
        conn |> put_flash(:error, "Authentication failed") |> redirect(to: ~p"/")
    end
  end

  def callback(%{assigns: %{ueberauth_auth: auth}} = conn, %{"provider" => "oidc"}) do
    case Accounts.register_user(%{
           sub: auth.uid,
           name: auth.info.name,
           avatar_url: auth.info.image
         }) do
      {:ok, user} ->
        UserAuth.log_in_user(conn, user, %{"remember_me" => "true"})

      {:error, _changeset} ->
        conn |> put_flash(:error, "Authentication failed") |> redirect(to: ~p"/")
    end
  end

  def callback(conn, _params) do
    conn
    |> put_flash(:error, "Authentication failed")
    |> redirect(to: ~p"/")
  end

  defp handle_mobile_callback(conn, user, redirect_uri) do
    exchange_code = Accounts.generate_user_exchange_token(user)
    encoded_exchange_code = Base.url_encode64(exchange_code, padding: false)

    redirect_url =
      URI.parse(redirect_uri)
      |> Map.put(:query, URI.encode_query(%{"exchange_code" => encoded_exchange_code}))
      |> URI.to_string()

    conn
    |> redirect(to: redirect_url)
  end
end
