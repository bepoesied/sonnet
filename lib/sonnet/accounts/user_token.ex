defmodule Sonnet.Accounts.UserToken do
  use Ecto.Schema
  import Ecto.Query
  alias Sonnet.Accounts.UserToken

  @rand_size 32
  @session_validity_in_days 14
  @exchange_validity_in_minutes 5
  @refresh_validity_in_days 30

  schema "users_tokens" do
    field :token, :binary
    field :context, :string
    field :sent_to, :string
    field :authenticated_at, :utc_datetime
    belongs_to :user, Sonnet.Accounts.User

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc """
  Generates a refresh token that can be used to obtain new access tokens.

  Refresh tokens are long-lived and can be used multiple times, but each
  use generates a new refresh token (token rotation).
  """
  def build_refresh_token(user) do
    token = :crypto.strong_rand_bytes(@rand_size)
    dt = user.authenticated_at || DateTime.utc_now() |> DateTime.truncate(:second)
    {token, %UserToken{token: token, context: "refresh", user_id: user.id, authenticated_at: dt}}
  end

  @doc """
  Checks if the refresh token is valid and returns its underlying lookup query.

  The query returns the user found by the token, if any, along with the token's creation time.

  The token is valid if it matches the value in the database and it has
  not expired (after @refresh_validity_in_days).
  """
  def verify_refresh_token_query(token) do
    query =
      from token in by_token_and_context_query(token, "refresh"),
        join: user in assoc(token, :user),
        where: token.inserted_at > ago(@refresh_validity_in_days, "day"),
        select: {%{user | authenticated_at: token.authenticated_at}, token.inserted_at}

    {:ok, query}
  end

  @doc """
  Generates a token that will be stored in a signed place,
  such as session or cookie. As they are signed, those
  tokens do not need to be hashed.

  The reason why we store session tokens in the database, even
  though Phoenix already provides a session cookie, is because
  Phoenix' default session cookies are not persisted, they are
  simply signed and potentially encrypted. This means they are
  valid indefinitely, unless you change the signing/encryption
  salt.

  Therefore, storing them allows individual user
  sessions to be expired. The token system can also be extended
  to store additional data, such as the device used for logging in.
  You could then use this information to display all valid sessions
  and devices in the UI and allow users to explicitly expire any
  session they deem invalid.
  """
  def build_session_token(user) do
    token = :crypto.strong_rand_bytes(@rand_size)
    dt = user.authenticated_at || DateTime.utc_now() |> DateTime.truncate(:second)
    {token, %UserToken{token: token, context: "session", user_id: user.id, authenticated_at: dt}}
  end

  @doc """
  Checks if the token is valid and returns its underlying lookup query.

  The query returns the user found by the token, if any, along with the token's creation time.

  The token is valid if it matches the value in the database and it has
  not expired (after @session_validity_in_days).
  """
  def verify_session_token_query(token) do
    query =
      from token in by_token_and_context_query(token, "session"),
        join: user in assoc(token, :user),
        where: token.inserted_at > ago(@session_validity_in_days, "day"),
        select: {%{user | authenticated_at: token.authenticated_at}, token.inserted_at}

    {:ok, query}
  end

  @doc """
  Generates an exchange code for token-based authentication flow.

  Exchange codes are single-use tokens that can be exchanged for
  access and refresh tokens. They expire quickly for security.
  """
  def build_exchange_token(user) do
    token = :crypto.strong_rand_bytes(@rand_size)
    {token, %UserToken{token: token, context: "exchange", user_id: user.id}}
  end

  @doc """
  Checks if the exchange code is valid and returns its underlying lookup query.

  The query returns the user found by the token, if any, along with the token itself.

  The token is valid if it matches the value in the database and it has
  not expired (after @exchange_validity_in_minutes).
  """
  def verify_exchange_token_query(token) do
    query =
      from token in by_token_and_context_query(token, "exchange"),
        join: user in assoc(token, :user),
        where: token.inserted_at > ago(@exchange_validity_in_minutes, "minute"),
        select: {user, token}

    {:ok, query}
  end

  defp by_token_and_context_query(token, context) do
    from UserToken, where: [token: ^token, context: ^context]
  end
end
