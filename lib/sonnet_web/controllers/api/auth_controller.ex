defmodule SonnetWeb.API.AuthController do
  use SonnetWeb, :controller

  alias Sonnet.Accounts
  alias Sonnet.MobileOIDC
  alias Sonnet.OIDCTokenVerifier
  alias SonnetWeb.UserSessionController

  def mobile_config(conn, _params) do
    case MobileOIDC.discovery() do
      {:ok, config} -> json(conn, config)
      {:error, _reason} -> render_error(conn, :oidc_unavailable)
    end
  end

  def oidc_login(conn, %{"id_token" => id_token}) do
    with {:ok, claims} <- OIDCTokenVerifier.verify_id_token(id_token),
         {:ok, user} <- upsert_user(claims) do
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
    else
      {:error, error} -> render_error(conn, error)
    end
  end

  def oidc_login(conn, _params), do: render_error(conn, :missing_token)

  def refresh(conn, params), do: UserSessionController.refresh(conn, params)

  def delete(conn, params), do: UserSessionController.delete(conn, params)

  defp upsert_user(claims) do
    Accounts.register_user(%{
      sub: claims["sub"],
      name: claims["name"],
      avatar_url: claims["picture"] || claims["avatar_url"]
    })
  end

  defp render_error(conn, error) do
    conn
    |> put_status(status_for_error(error))
    |> json(%{error: error_message(error)})
  end

  defp status_for_error(error) when error in [:missing_token, :malformed_token], do: :bad_request
  defp status_for_error(:oidc_unavailable), do: :service_unavailable
  defp status_for_error(_error), do: :unauthorized

  defp error_message(:missing_token), do: "missing_token"
  defp error_message(:malformed_token), do: "malformed_token"
  defp error_message(:invalid_issuer), do: "invalid_issuer"
  defp error_message(:invalid_audience), do: "invalid_audience"
  defp error_message(:expired_token), do: "expired_token"
  defp error_message(:missing_subject), do: "missing_subject"
  defp error_message(:invalid_signature), do: "invalid_signature"
  defp error_message(:oidc_unavailable), do: "oidc_unavailable"
  defp error_message(_error), do: "invalid_token"
end
