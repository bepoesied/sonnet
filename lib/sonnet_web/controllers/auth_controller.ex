defmodule SonnetWeb.AuthController do
  alias SonnetWeb.UserAuth
  alias Sonnet.Accounts
  use SonnetWeb, :controller

  plug Ueberauth

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
end
