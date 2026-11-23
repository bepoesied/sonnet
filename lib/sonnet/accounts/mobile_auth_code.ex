defmodule Sonnet.Accounts.MobileAuthCode do
  @moduledoc """
  Short-lived, single-use, PKCE-bound authorization codes used to hand off an
  authenticated OIDC login from the browser callback to a native mobile client.

  Security invariants:
  - Codes have 256 bits of CSPRNG entropy (`:crypto.strong_rand_bytes(32)`).
  - Only the SHA-256 digest of the raw code is persisted (`code_hash`).
  - Codes expire after 60 seconds and are consumed atomically on first attempt.
  - PKCE `S256` (`code_challenge` / `code_verifier`) is mandatory (`plain` is rejected).
  - Redirect URIs are validated by exact allowlist equality and re-verified on exchange.
  """

  use Ecto.Schema

  @code_bytes 32
  @validity_in_seconds 60

  # RFC 7636 §4.1: unreserved characters, 43..128 bytes
  @pkce_verifier_regex ~r/\A[A-Za-z0-9\-._~]{43,128}\z/
  # Base64url (no padding) of a 32-byte SHA-256 digest is always 43 characters
  @pkce_challenge_regex ~r/\A[A-Za-z0-9_-]{43}\z/
  # URL-safe opaque CSRF state from mobile client, 16..512 characters
  @state_regex ~r/\A[A-Za-z0-9\-._~]{16,512}\z/

  schema "mobile_auth_codes" do
    field :code_hash, :binary
    field :code_challenge, :string
    field :redirect_uri, :string
    field :expires_at, :utc_datetime
    belongs_to :user, Sonnet.Accounts.User

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def validity_in_seconds, do: @validity_in_seconds

  @doc """
  Validates query parameters submitted to `GET /auth/mobile/authorize`.
  """
  def validate_authorize_params(params, allowed_redirect_uris)
      when is_map(params) and is_list(allowed_redirect_uris) do
    with {:ok, redirect_uri} <-
           validate_redirect_uri(Map.get(params, "redirect_uri"), allowed_redirect_uris),
         :ok <- validate_code_challenge_method(Map.get(params, "code_challenge_method")),
         {:ok, code_challenge} <- validate_code_challenge(Map.get(params, "code_challenge")),
         {:ok, state} <- validate_state(Map.get(params, "state")) do
      {:ok,
       %{
         redirect_uri: redirect_uri,
         code_challenge: code_challenge,
         state: state
       }}
    end
  end

  @doc """
  Builds a new one-time handoff code and its database struct.

  Returns `{encoded_code, %MobileAuthCode{}}`, where `encoded_code` is sent
  once to the mobile redirect URI and only its SHA-256 hash is stored.
  """
  def build(user, %{code_challenge: code_challenge, redirect_uri: redirect_uri}, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:second))
    raw_code = :crypto.strong_rand_bytes(@code_bytes)
    code_hash = :crypto.hash(:sha256, raw_code)
    encoded_code = Base.url_encode64(raw_code, padding: false)

    struct = %__MODULE__{
      code_hash: code_hash,
      user_id: user.id,
      code_challenge: code_challenge,
      redirect_uri: redirect_uri,
      expires_at: DateTime.add(now, @validity_in_seconds, :second)
    }

    {encoded_code, struct}
  end

  @doc """
  Decodes a base64url handoff code and returns its SHA-256 digest.
  """
  def hash_encoded_code(encoded_code) when is_binary(encoded_code) do
    case Base.url_decode64(encoded_code, padding: false) do
      {:ok, raw_code} when byte_size(raw_code) == @code_bytes ->
        {:ok, :crypto.hash(:sha256, raw_code)}

      _ ->
        :error
    end
  end

  def hash_encoded_code(_), do: :error

  @doc """
  Verifies a PKCE `code_verifier` against the stored `S256` `code_challenge`
  in constant time.
  """
  def verify_pkce(code_verifier, expected_code_challenge)
      when is_binary(code_verifier) and is_binary(expected_code_challenge) do
    if valid_code_verifier?(code_verifier) do
      computed_challenge =
        :crypto.hash(:sha256, code_verifier)
        |> Base.url_encode64(padding: false)

      Plug.Crypto.secure_compare(computed_challenge, expected_code_challenge)
    else
      false
    end
  end

  def verify_pkce(_, _), do: false

  @doc """
  Returns whether `code_verifier` conforms to RFC 7636 §4.1.
  """
  def valid_code_verifier?(code_verifier) when is_binary(code_verifier) do
    Regex.match?(@pkce_verifier_regex, code_verifier)
  end

  def valid_code_verifier?(_), do: false

  @doc """
  Compares the `redirect_uri` provided during exchange against the stored one
  in constant time.
  """
  def verify_redirect_uri(given, expected) when is_binary(given) and is_binary(expected) do
    Plug.Crypto.secure_compare(given, expected)
  end

  def verify_redirect_uri(_, _), do: false

  @doc """
  Appends query parameters safely to an allowlisted redirect URI.
  """
  def append_query_params(redirect_uri, params) when is_binary(redirect_uri) and is_map(params) do
    uri = URI.parse(redirect_uri)

    existing_query =
      case uri.query do
        nil -> %{}
        query -> URI.decode_query(query)
      end

    merged_query =
      existing_query
      |> Map.merge(Map.new(params, fn {k, v} -> {to_string(k), to_string(v)} end))
      |> URI.encode_query()

    URI.to_string(%{uri | query: merged_query})
  end

  @doc """
  Checks whether a configured allowlist entry is a well-formed absolute URI
  without a fragment.
  """
  def valid_allowlist_uri?(uri) when is_binary(uri) and uri != "" do
    case URI.parse(uri) do
      %URI{scheme: scheme, fragment: nil} when is_binary(scheme) and scheme != "" ->
        true

      _ ->
        false
    end
  end

  def valid_allowlist_uri?(_), do: false

  defp validate_redirect_uri(redirect_uri, allowed_redirect_uris)
       when is_binary(redirect_uri) and redirect_uri != "" do
    if valid_allowlist_uri?(redirect_uri) and
         Enum.any?(allowed_redirect_uris, fn allowed ->
           valid_allowlist_uri?(allowed) and Plug.Crypto.secure_compare(redirect_uri, allowed)
         end) do
      {:ok, redirect_uri}
    else
      {:error, :invalid_redirect_uri}
    end
  end

  defp validate_redirect_uri(_, _), do: {:error, :invalid_redirect_uri}

  defp validate_code_challenge_method("S256"), do: :ok
  defp validate_code_challenge_method(_), do: {:error, :invalid_code_challenge_method}

  defp validate_code_challenge(code_challenge) when is_binary(code_challenge) do
    if Regex.match?(@pkce_challenge_regex, code_challenge) do
      {:ok, code_challenge}
    else
      {:error, :invalid_code_challenge}
    end
  end

  defp validate_code_challenge(_), do: {:error, :invalid_code_challenge}

  defp validate_state(state) when is_binary(state) do
    if Regex.match?(@state_regex, state) do
      {:ok, state}
    else
      {:error, :invalid_state}
    end
  end

  defp validate_state(_), do: {:error, :invalid_state}
end
