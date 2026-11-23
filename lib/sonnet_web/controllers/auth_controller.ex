defmodule SonnetWeb.AuthController do
  use SonnetWeb, :controller

  alias Oidcc.Plug.AuthorizationCallback
  alias Oidcc.Plug.Authorize
  alias Sonnet.Accounts
  alias Sonnet.Accounts.MobileAuthCode
  alias SonnetWeb.UserAuth

  @mobile_auth_session_key :mobile_auth
  @mobile_state_prefix "mobile:"

  plug :prepare_web_authorize when action in [:authorize]
  plug :prepare_mobile_authorize when action in [:mobile_authorize]

  plug Authorize,
       [
         provider: Application.compile_env(:sonnet, [__MODULE__, :provider]),
         client_id: &__MODULE__.client_id/0,
         client_secret: &__MODULE__.client_secret/0,
         redirect_uri: &__MODULE__.callback_uri/0,
         scopes: ["openid", "profile"]
       ]
       when action in [:authorize, :mobile_authorize]

  plug AuthorizationCallback,
       [
         provider: Application.compile_env(:sonnet, [__MODULE__, :provider]),
         client_id: &__MODULE__.client_id/0,
         client_secret: &__MODULE__.client_secret/0,
         redirect_uri: &__MODULE__.callback_uri/0,
         check_peer_ip: false
       ]
       when action in [:callback]

  def authorize(conn, _params), do: conn

  def mobile_authorize(conn, _params), do: conn

  def callback(conn, _params) do
    conn = put_no_store_headers(conn)
    mobile_auth = get_session(conn, @mobile_auth_session_key)
    conn = delete_session(conn, @mobile_auth_session_key)

    case resolve_flow(conn, mobile_auth) do
      {:mobile, validated_mobile_auth} ->
        handle_mobile_callback(conn, validated_mobile_auth)

      :web ->
        handle_web_callback(conn)

      {:error, :invalid_flow_state} ->
        conn
        |> clear_ephemeral_session()
        |> put_status(:bad_request)
        |> render(:error, reason: :invalid_flow_state)
    end
  end

  def delete(conn, _params) do
    conn
    |> put_flash(:info, "Signed out successfully.")
    |> UserAuth.log_out_user()
  end

  @doc false
  def client_id do
    Application.fetch_env!(:sonnet, __MODULE__)[:client_id]
  end

  @doc false
  def client_secret do
    Application.fetch_env!(:sonnet, __MODULE__)[:client_secret]
  end

  @doc false
  def callback_uri do
    url(~p"/auth/callback")
  end

  @doc false
  def mobile_redirect_uris do
    Application.get_env(:sonnet, __MODULE__, [])
    |> Keyword.get(:mobile_redirect_uris, ["sonnet://auth/callback"])
  end

  defp prepare_web_authorize(conn, _opts) do
    conn
    |> put_no_store_headers()
    |> delete_session(@mobile_auth_session_key)
    |> Map.update!(:params, &Map.delete(&1, "state"))
  end

  defp prepare_mobile_authorize(conn, _opts) do
    conn = put_no_store_headers(conn)

    case MobileAuthCode.validate_authorize_params(conn.params, mobile_redirect_uris()) do
      {:ok, mobile_params} ->
        flow_id = 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

        mobile_session = %{
          "flow_id" => flow_id,
          "redirect_uri" => mobile_params.redirect_uri,
          "code_challenge" => mobile_params.code_challenge,
          "state" => mobile_params.state
        }

        conn
        |> put_session(@mobile_auth_session_key, mobile_session)
        |> Map.update!(:params, &Map.put(&1, "state", @mobile_state_prefix <> flow_id))

      {:error, reason} ->
        conn
        |> delete_session(@mobile_auth_session_key)
        |> put_status(:bad_request)
        |> render(:error, reason: reason)
        |> halt()
    end
  end

  defp resolve_flow(conn, mobile_auth) do
    state = Map.get(conn.private, Authorize.State)

    case {state, mobile_auth} do
      {@mobile_state_prefix <> flow_id,
       %{
         "flow_id" => expected_flow_id,
         "redirect_uri" => redirect_uri,
         "code_challenge" => code_challenge,
         "state" => mobile_state
       }}
      when is_binary(expected_flow_id) and is_binary(redirect_uri) and
             is_binary(code_challenge) and is_binary(mobile_state) ->
        if Plug.Crypto.secure_compare(flow_id, expected_flow_id) and
             redirect_uri_allowed?(redirect_uri) do
          {:mobile,
           %{
             redirect_uri: redirect_uri,
             code_challenge: code_challenge,
             state: mobile_state
           }}
        else
          {:error, :invalid_flow_state}
        end

      {nil, nil} ->
        :web

      _ ->
        {:error, :invalid_flow_state}
    end
  end

  defp handle_web_callback(
         %Plug.Conn{private: %{AuthorizationCallback => {:ok, {_token, userinfo}}}} = conn
       ) do
    case Accounts.upsert_user(userinfo) do
      {:ok, user} ->
        conn
        |> put_flash(:info, "Signed in successfully.")
        |> UserAuth.log_in_user(user, %{"remember_me" => "true"})

      {:error, _changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> render(:error, reason: :user_provisioning_failed)
    end
  end

  defp handle_web_callback(
         %Plug.Conn{private: %{AuthorizationCallback => {:error, _reason}}} = conn
       ) do
    conn
    |> put_status(:bad_request)
    |> render(:error, reason: :authentication_failed)
  end

  defp handle_web_callback(conn) do
    conn
    |> put_status(:bad_request)
    |> render(:error, reason: :authentication_failed)
  end

  defp handle_mobile_callback(
         %Plug.Conn{private: %{AuthorizationCallback => {:ok, {_token, userinfo}}}} = conn,
         mobile_auth
       ) do
    with {:ok, user} <- Accounts.upsert_user(userinfo),
         {:ok, code} <-
           Accounts.create_mobile_auth_code(user, %{
             code_challenge: mobile_auth.code_challenge,
             redirect_uri: mobile_auth.redirect_uri
           }) do
      redirect_url =
        MobileAuthCode.append_query_params(mobile_auth.redirect_uri, %{
          code: code,
          state: mobile_auth.state
        })

      conn
      |> clear_ephemeral_session()
      |> put_resp_header("referrer-policy", "no-referrer")
      |> redirect(external: redirect_url)
    else
      {:error, _reason} ->
        redirect_mobile_error(conn, mobile_auth, "authentication_failed")
    end
  end

  defp handle_mobile_callback(conn, mobile_auth) do
    redirect_mobile_error(conn, mobile_auth, "authentication_failed")
  end

  defp redirect_mobile_error(conn, mobile_auth, error_code) do
    redirect_url =
      MobileAuthCode.append_query_params(mobile_auth.redirect_uri, %{
        error: error_code,
        state: mobile_auth.state
      })

    conn
    |> clear_ephemeral_session()
    |> put_resp_header("referrer-policy", "no-referrer")
    |> redirect(external: redirect_url)
  end

  defp redirect_uri_allowed?(redirect_uri) do
    MobileAuthCode.valid_allowlist_uri?(redirect_uri) and
      Enum.any?(mobile_redirect_uris(), fn allowed ->
        MobileAuthCode.valid_allowlist_uri?(allowed) and
          Plug.Crypto.secure_compare(redirect_uri, allowed)
      end)
  end

  defp clear_ephemeral_session(conn) do
    conn
    |> configure_session(renew: true)
    |> clear_session()
  end

  defp put_no_store_headers(conn) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("pragma", "no-cache")
  end
end
