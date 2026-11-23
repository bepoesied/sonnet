defmodule Sonnet.Accounts.MobileAuthCodeTest do
  use Sonnet.DataCase, async: false

  alias Sonnet.Accounts
  alias Sonnet.Accounts.MobileAuthCode
  alias Sonnet.Repo

  @allowed_uris ["sonnet://auth/callback", "exp://localhost:8081/--/auth/callback"]

  defp pkce_pair do
    verifier = 48 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
    {verifier, challenge}
  end

  defp valid_state do
    24 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  defp user_fixture do
    {:ok, user} = Accounts.register_user(%{sub: Ecto.UUID.generate(), name: "Mobile User"})
    user
  end

  describe "validate_authorize_params/2" do
    test "accepts exact allowlisted redirect_uri, S256 challenge, and valid state" do
      {_verifier, challenge} = pkce_pair()
      state = valid_state()

      assert {:ok,
              %{
                redirect_uri: "sonnet://auth/callback",
                code_challenge: ^challenge,
                state: ^state
              }} =
               MobileAuthCode.validate_authorize_params(
                 %{
                   "redirect_uri" => "sonnet://auth/callback",
                   "code_challenge" => challenge,
                   "code_challenge_method" => "S256",
                   "state" => state
                 },
                 @allowed_uris
               )
    end

    test "rejects non-exact redirect_uri attempts (prefix, query, scheme, fragment)" do
      {_verifier, challenge} = pkce_pair()
      state = valid_state()

      invalid_uris = [
        nil,
        "",
        "https://evil.example/callback",
        "sonnet://auth/callback/extra",
        "sonnet://auth/callback?foo=bar",
        "sonnet://auth/callback#frag",
        "sonnet://evil.example/callback",
        "javascript:alert(1)"
      ]

      for uri <- invalid_uris do
        assert {:error, :invalid_redirect_uri} =
                 MobileAuthCode.validate_authorize_params(
                   %{
                     "redirect_uri" => uri,
                     "code_challenge" => challenge,
                     "code_challenge_method" => "S256",
                     "state" => state
                   },
                   @allowed_uris
                 )
      end
    end

    test "rejects plain or missing code_challenge_method" do
      {_verifier, challenge} = pkce_pair()
      state = valid_state()

      for method <- [nil, "", "plain", "s256", "SHA256"] do
        assert {:error, :invalid_code_challenge_method} =
                 MobileAuthCode.validate_authorize_params(
                   %{
                     "redirect_uri" => "sonnet://auth/callback",
                     "code_challenge" => challenge,
                     "code_challenge_method" => method,
                     "state" => state
                   },
                   @allowed_uris
                 )
      end
    end

    test "rejects malformed code_challenge values" do
      state = valid_state()

      for challenge <- [
            nil,
            "",
            "too-short",
            String.duplicate("a", 44),
            String.duplicate("=", 43)
          ] do
        assert {:error, :invalid_code_challenge} =
                 MobileAuthCode.validate_authorize_params(
                   %{
                     "redirect_uri" => "sonnet://auth/callback",
                     "code_challenge" => challenge,
                     "code_challenge_method" => "S256",
                     "state" => state
                   },
                   @allowed_uris
                 )
      end
    end

    test "rejects missing, short, or invalid state values" do
      {_verifier, challenge} = pkce_pair()

      for state <- [nil, "", "short", "has spaces in state value", "has\nnewline12345678"] do
        assert {:error, :invalid_state} =
                 MobileAuthCode.validate_authorize_params(
                   %{
                     "redirect_uri" => "sonnet://auth/callback",
                     "code_challenge" => challenge,
                     "code_challenge_method" => "S256",
                     "state" => state
                   },
                   @allowed_uris
                 )
      end
    end
  end

  describe "create_mobile_auth_code/2 and consume_mobile_auth_code/3" do
    test "stores only SHA-256 hash at rest and consumes once with valid PKCE" do
      user = user_fixture()
      {verifier, challenge} = pkce_pair()

      {:ok, encoded_code} =
        Accounts.create_mobile_auth_code(user, %{
          code_challenge: challenge,
          redirect_uri: "sonnet://auth/callback"
        })

      {:ok, raw_code} = Base.url_decode64(encoded_code, padding: false)
      assert byte_size(raw_code) == 32

      stored = Repo.one!(MobileAuthCode)
      assert stored.code_hash == :crypto.hash(:sha256, raw_code)
      refute stored.code_hash == raw_code
      refute stored.code_hash == encoded_code

      assert {:ok, consumed_user} =
               Accounts.consume_mobile_auth_code(encoded_code, verifier, "sonnet://auth/callback")

      assert consumed_user.id == user.id
      assert Repo.all(MobileAuthCode) == []

      # Replay must fail
      assert {:error, :invalid_grant} =
               Accounts.consume_mobile_auth_code(encoded_code, verifier, "sonnet://auth/callback")
    end

    test "burns the code immediately when code_verifier does not match" do
      user = user_fixture()
      {verifier, challenge} = pkce_pair()
      {wrong_verifier, _} = pkce_pair()

      {:ok, encoded_code} =
        Accounts.create_mobile_auth_code(user, %{
          code_challenge: challenge,
          redirect_uri: "sonnet://auth/callback"
        })

      assert {:error, :invalid_grant} =
               Accounts.consume_mobile_auth_code(
                 encoded_code,
                 wrong_verifier,
                 "sonnet://auth/callback"
               )

      assert Repo.all(MobileAuthCode) == []

      # Even the real verifier cannot redeem it afterwards
      assert {:error, :invalid_grant} =
               Accounts.consume_mobile_auth_code(encoded_code, verifier, "sonnet://auth/callback")
    end

    test "burns the code immediately when redirect_uri does not match" do
      user = user_fixture()
      {verifier, challenge} = pkce_pair()

      {:ok, encoded_code} =
        Accounts.create_mobile_auth_code(user, %{
          code_challenge: challenge,
          redirect_uri: "sonnet://auth/callback"
        })

      assert {:error, :invalid_grant} =
               Accounts.consume_mobile_auth_code(
                 encoded_code,
                 verifier,
                 "exp://localhost:8081/--/auth/callback"
               )

      assert Repo.all(MobileAuthCode) == []

      assert {:error, :invalid_grant} =
               Accounts.consume_mobile_auth_code(encoded_code, verifier, "sonnet://auth/callback")
    end

    test "rejects expired codes and deletes them" do
      user = user_fixture()
      {verifier, challenge} = pkce_pair()
      expired_time = DateTime.add(DateTime.utc_now(:second), -120, :second)

      {encoded_code, struct} =
        MobileAuthCode.build(
          user,
          %{code_challenge: challenge, redirect_uri: "sonnet://auth/callback"},
          now: expired_time
        )

      Repo.insert!(struct)

      assert {:error, :invalid_grant} =
               Accounts.consume_mobile_auth_code(encoded_code, verifier, "sonnet://auth/callback")

      assert Repo.all(MobileAuthCode) == []
    end

    test "allows at most one winner under concurrent redemption attempts" do
      user = user_fixture()
      {verifier, challenge} = pkce_pair()

      {:ok, encoded_code} =
        Accounts.create_mobile_auth_code(user, %{
          code_challenge: challenge,
          redirect_uri: "sonnet://auth/callback"
        })

      results =
        1..6
        |> Enum.map(fn _ ->
          Task.async(fn ->
            Accounts.consume_mobile_auth_code(encoded_code, verifier, "sonnet://auth/callback")
          end)
        end)
        |> Enum.map(&Task.await/1)

      successes = Enum.filter(results, &match?({:ok, _}, &1))
      failures = Enum.filter(results, &(&1 == {:error, :invalid_grant}))

      assert length(successes) == 1
      assert length(failures) == 5
    end
  end
end
