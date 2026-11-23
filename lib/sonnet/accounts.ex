defmodule Sonnet.Accounts do
  @moduledoc """
  The Accounts context.
  """

  import Ecto.Query, warn: false
  alias Sonnet.Repo

  alias Sonnet.Accounts.{User, UserToken}

  @mobile_code_salt "mobile auth handoff"
  @mobile_code_max_age 60
  # RFC 7636 §4.1: unreserved characters, 43..128 bytes
  @pkce_verifier_regex ~r/\A[A-Za-z0-9\-._~]{43,128}\z/

  ## Database getters
  def get_user_by_sub(sub) when is_binary(sub) do
    Repo.get_by(User, sub: sub)
  end

  @doc """
  Gets a single user.

  Raises `Ecto.NoResultsError` if the User does not exist.

  ## Examples

      iex> get_user!(123)
      %User{}

      iex> get_user!(456)
      ** (Ecto.NoResultsError)

  """
  def get_user!(id), do: Repo.get!(User, id)

  ## User registration

  @doc """
  Finds the local user for an OIDC subject, creating it when first seen and
  refreshing display name and avatar URL from standard OIDC claims.
  """
  @spec upsert_user(map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def upsert_user(userinfo) when is_map(userinfo) do
    register_user(%{
      sub: Map.get(userinfo, "sub"),
      name: Map.get(userinfo, "name"),
      avatar_url: Map.get(userinfo, "picture")
    })
  end

  @doc """
  Registers a user.

  ## Examples

      iex> register_user(%{field: value})
      {:ok, %User{}}

      iex> register_user(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def register_user(attrs) do
    %User{}
    |> User.oidc_changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:name, :avatar_url, :updated_at]},
      conflict_target: :sub,
      returning: true
    )
  end

  ## Settings

  @doc """
  Checks whether the user is in sudo mode.

  The user is in sudo mode when the last authentication was done no further
  than 20 minutes ago. The limit can be given as second argument in minutes.
  """
  def sudo_mode?(user, minutes \\ -20)

  def sudo_mode?(%User{authenticated_at: ts}, minutes) when is_struct(ts, DateTime) do
    DateTime.after?(ts, DateTime.utc_now() |> DateTime.add(minutes, :minute))
  end

  def sudo_mode?(_user, _minutes), do: false

  ## Session

  @doc """
  Generates a session token.
  """
  def generate_user_session_token(user) do
    {token, user_token} = UserToken.build_session_token(user)
    Repo.insert!(user_token)
    token
  end

  @doc """
  Generates a refresh token for obtaining new access tokens.
  """
  def generate_user_refresh_token(user) do
    {token, refresh_token} = UserToken.build_refresh_token(user)
    Repo.insert!(refresh_token)
    token
  end

  @doc """
  Gets the user with the given access token.

  If the token is valid `{user, token_inserted_at}` is returned, otherwise `nil` is returned.
  """
  def get_user_by_session_token(token) do
    {:ok, query} = UserToken.verify_session_token_query(token)
    Repo.one(query)
  end

  @doc """
  Gets the user with the given refresh token.

  If the token is valid `{user, token_inserted_at}` is returned, otherwise `nil` is returned.
  """
  def get_user_by_refresh_token(token) do
    {:ok, query} = UserToken.verify_refresh_token_query(token)
    Repo.one(query)
  end

  @doc """
  Deletes the access token with the given token.
  """
  def delete_user_session_token(token) do
    Repo.delete_all(from(UserToken, where: [token: ^token, context: "session"]))
    :ok
  end

  @doc """
  Deletes the refresh token with the given token.
  """
  def delete_user_refresh_token(token) do
    Repo.delete_all(from(UserToken, where: [token: ^token, context: "refresh"]))
    :ok
  end

  @doc """
  Atomically consumes a valid refresh token and rotates it into a new
  `{access_token, refresh_token}` pair.
  """
  def rotate_user_refresh_token(token) when is_binary(token) do
    cutoff = DateTime.add(DateTime.utc_now(:second), -30, :day)

    Repo.transaction(fn ->
      query =
        from t in UserToken,
          where: t.token == ^token and t.context == "refresh",
          select: t

      case Repo.delete_all(query) do
        {1, [%UserToken{user_id: user_id, inserted_at: inserted_at, authenticated_at: auth_at}]} ->
          if DateTime.after?(inserted_at, cutoff) do
            case Repo.get(User, user_id) do
              %User{} = user ->
                user = %{user | authenticated_at: auth_at}
                {generate_user_session_token(user), generate_user_refresh_token(user)}

              nil ->
                Repo.rollback(:invalid_refresh_token)
            end
          else
            Repo.rollback(:invalid_refresh_token)
          end

        _ ->
          Repo.rollback(:invalid_refresh_token)
      end
    end)
  end

  ## Mobile OIDC Handoff Codes

  @doc """
  Creates a short-lived (60s), single-use, PKCE-bound handoff code for mobile
  login using `Phoenix.Token.encrypt/4` backed by a one-time `UserToken` nonce.
  """
  def create_mobile_auth_code(
        %User{} = user,
        %{code_challenge: code_challenge, redirect_uri: redirect_uri},
        opts \\ []
      ) do
    prune_expired_mobile_auth_codes()

    {nonce, user_token} = UserToken.build_mobile_code_token(user)
    Repo.insert!(user_token)

    code =
      Phoenix.Token.encrypt(
        SonnetWeb.Endpoint,
        @mobile_code_salt,
        %{nonce: nonce, code_challenge: code_challenge, redirect_uri: redirect_uri},
        opts
      )

    {:ok, code}
  end

  @doc """
  Atomically consumes a mobile handoff code and validates `Phoenix.Token`
  authenticity/expiry, exact `redirect_uri`, and PKCE `S256` `code_verifier`.

  The one-time `UserToken` nonce is deleted atomically on the first redemption
  attempt — even if `code_verifier` or `redirect_uri` does not match —
  preventing replay, brute-force retries, and concurrent exchange races.
  """
  def consume_mobile_auth_code(code, code_verifier, redirect_uri)
      when is_binary(code) and is_binary(code_verifier) and is_binary(redirect_uri) do
    with {:ok,
          %{nonce: nonce, code_challenge: code_challenge, redirect_uri: expected_redirect_uri}} <-
           Phoenix.Token.decrypt(SonnetWeb.Endpoint, @mobile_code_salt, code,
             max_age: @mobile_code_max_age
           ),
         {1, [%UserToken{user_id: user_id}]} <- delete_mobile_code_nonce(nonce),
         true <- Plug.Crypto.secure_compare(redirect_uri, expected_redirect_uri),
         true <- verify_pkce_s256(code_verifier, code_challenge),
         %User{} = user <- Repo.get(User, user_id) do
      {:ok, user}
    else
      _ -> {:error, :invalid_grant}
    end
  end

  def consume_mobile_auth_code(_, _, _), do: {:error, :invalid_grant}

  defp delete_mobile_code_nonce(nonce) when is_binary(nonce) do
    from(t in UserToken, where: t.token == ^nonce and t.context == "mobile_code", select: t)
    |> Repo.delete_all()
  end

  defp prune_expired_mobile_auth_codes do
    cutoff = DateTime.add(DateTime.utc_now(:second), -@mobile_code_max_age, :second)

    Repo.delete_all(
      from t in UserToken, where: t.context == "mobile_code" and t.inserted_at <= ^cutoff
    )

    :ok
  end

  defp verify_pkce_s256(code_verifier, expected_challenge) do
    if Regex.match?(@pkce_verifier_regex, code_verifier) do
      computed = :crypto.hash(:sha256, code_verifier) |> Base.url_encode64(padding: false)
      Plug.Crypto.secure_compare(computed, expected_challenge)
    else
      false
    end
  end
end
