defmodule Sonnet.Accounts do
  @moduledoc """
  The Accounts context.
  """

  import Ecto.Query, warn: false
  alias Sonnet.Repo

  alias Sonnet.Accounts.{MobileAuthCode, User, UserToken}

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
  Creates a short-lived, single-use, PKCE-bound handoff code for mobile login.

  Returns `{:ok, encoded_code}`. Only the SHA-256 hash of the code is stored in
  the database.
  """
  def create_mobile_auth_code(%User{} = user, %{
        code_challenge: code_challenge,
        redirect_uri: redirect_uri
      }) do
    prune_expired_mobile_auth_codes()

    {encoded_code, auth_code} =
      MobileAuthCode.build(user, %{
        code_challenge: code_challenge,
        redirect_uri: redirect_uri
      })

    Repo.insert!(auth_code)
    {:ok, encoded_code}
  end

  @doc """
  Atomically consumes a mobile handoff code and validates expiration, exact
  `redirect_uri`, and PKCE `S256` `code_verifier`.

  The code is deleted atomically on the first redemption attempt — even if the
  `code_verifier` or `redirect_uri` does not match — preventing replay,
  brute-force retries, and concurrent exchange races.
  """
  def consume_mobile_auth_code(encoded_code, code_verifier, redirect_uri)
      when is_binary(encoded_code) and is_binary(code_verifier) and is_binary(redirect_uri) do
    with {:ok, code_hash} <- MobileAuthCode.hash_encoded_code(encoded_code),
         {1, [%MobileAuthCode{} = auth_code]} <- delete_mobile_auth_code_by_hash(code_hash),
         true <- DateTime.after?(auth_code.expires_at, DateTime.utc_now(:second)),
         true <- MobileAuthCode.verify_redirect_uri(redirect_uri, auth_code.redirect_uri),
         true <- MobileAuthCode.verify_pkce(code_verifier, auth_code.code_challenge),
         %User{} = user <- Repo.get(User, auth_code.user_id) do
      {:ok, user}
    else
      _ -> {:error, :invalid_grant}
    end
  end

  def consume_mobile_auth_code(_, _, _), do: {:error, :invalid_grant}

  @doc """
  Deletes all expired mobile handoff codes.
  """
  def prune_expired_mobile_auth_codes(now \\ DateTime.utc_now(:second)) do
    Repo.delete_all(from c in MobileAuthCode, where: c.expires_at <= ^now)
    :ok
  end

  defp delete_mobile_auth_code_by_hash(code_hash) do
    from(c in MobileAuthCode, where: c.code_hash == ^code_hash, select: c)
    |> Repo.delete_all()
  end
end
