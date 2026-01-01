defmodule Sonnet.Accounts do
  @moduledoc """
  The Accounts context.
  """

  import Ecto.Query, warn: false
  alias Sonnet.Repo

  alias Sonnet.Accounts.{User, UserToken}

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
      on_conflict: {:replace_all_except, [:id, :inserted_at]},
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
  Generates an exchange code for token-based authentication.
  """
  def generate_user_exchange_token(user) do
    {token, exchange_token} = UserToken.build_exchange_token(user)
    Repo.insert!(exchange_token)
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
  Gets the user and exchange token with the given exchange code.

  If the code is valid `{user, exchange_token}` is returned, otherwise `nil` is returned.
  """
  def get_user_by_exchange_code(token) do
    {:ok, query} = UserToken.verify_exchange_token_query(token)
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
  Deletes the exchange code with the given token.
  """
  def delete_exchange_code(token) do
    Repo.delete_all(from(UserToken, where: [token: ^token, context: "exchange"]))
    :ok
  end
end
