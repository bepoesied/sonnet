defmodule SonnetWeb.AuthController do
  use SonnetWeb, :controller

  alias Oidcc.Plug.AuthorizationCallback
  alias Oidcc.Plug.Authorize
  alias Sonnet.Accounts
  alias SonnetWeb.UserAuth

  @mobile_auth_session_key :mobile_auth
  @mobile_state_prefix "mobile:"
  # Base64url (no padding) of a 32-byte SHA-256 digest is always 43 characters
  @pkce_challenge_regex ~r/\A[A-Za-z0-9_-]{43}\z/
  # URL-safe opaque CSRF state from mobile client, 16..512 characters
  @state_regex ~r/\A[A-Za-z0-9\-._~]{16,512}\z/

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

    case validate_mobile_authorize_params(conn.params) do
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

  defp validate_mobile_authorize_params(params) do
    with redirect_uri when is_binary(redirect_uri) <- Map.get(params, "redirect_uri"),
         true <- redirect_uri_allowed?(redirect_uri),
         :ok <- validate_challenge_method(Map.get(params, "code_challenge_method")),
         {:ok, code_challenge} <- validate_code_challenge(Map.get(params, "code_challenge")),
         {:ok, state} <- validate_state(Map.get(params, "state")) do
      {:ok, %{redirect_uri: redirect_uri, code_challenge: code_challenge, state: state}}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_redirect_uri}
    end
  end

  defp validate_challenge_method("S256"), do: :ok
  defp validate_challenge_method(_), do: {:error, :invalid_code_challenge_method}

  defp validate_code_challenge(challenge) when is_binary(challenge) do
    if Regex.match?(@pkce_challenge_regex, challenge),
      do: {:ok, challenge},
      else: {:error, :invalid_code_challenge}
  end

  defp validate_code_challenge(_), do: {:error, :invalid_code_challenge}

  defp validate_state(state) when is_binary(state) do
    if Regex.match?(@state_regex, state),
      do: {:ok, state},
      else: {:error, :invalid_state}
  end

  defp validate_state(_), do: {:error, :invalid_state}

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
        append_query_params(mobile_auth.redirect_uri, %{code: code, state: mobile_auth.state})

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
      append_query_params(mobile_auth.redirect_uri, %{
        error: error_code,
        state: mobile_auth.state
      })

    conn
    |> clear_ephemeral_session()
    |> put_resp_header("referrer-policy", "no-referrer")
    |> redirect(external: redirect_url)
  end

  defp redirect_uri_allowed?(redirect_uri) when is_binary(redirect_uri) and redirect_uri != "" do
    Enum.any?(mobile_redirect_uris(), fn allowed ->
      is_binary(allowed) and allowed != "" and Plug.Crypto.secure_compare(redirect_uri, allowed)
    end)
  end

  defp redirect_uri_allowed?(_), do: false

  defp append_query_params(redirect_uri, params) do
    uri = URI.parse(redirect_uri)
    query = URI.encode_query(params)
    URI.to_string(%{uri | query: query})
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
