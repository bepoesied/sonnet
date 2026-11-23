defmodule Sonnet.AccountsTest do
  use Sonnet.DataCase, async: false

  alias Sonnet.Accounts
  alias Sonnet.Accounts.{User, UserToken}

  defp pkce_pair do
    verifier = 48 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
    {verifier, challenge}
  end

  defp mobile_code_rows do
    Repo.all(from t in UserToken, where: t.context == "mobile_code")
  end

  describe "session and refresh tokens" do
    test "generate and fetch session tokens with authenticated_at" do
      user =
        Repo.insert!(%User{sub: "session-user", name: "Session User"})

      before_token = DateTime.utc_now() |> DateTime.truncate(:second)
      token = Accounts.generate_user_session_token(user)
      after_token = DateTime.utc_now() |> DateTime.truncate(:second)

      assert {%User{} = fetched_user, inserted_at} = Accounts.get_user_by_session_token(token)
      assert fetched_user.id == user.id
      assert is_struct(inserted_at, DateTime)
      assert DateTime.compare(fetched_user.authenticated_at, before_token) in [:eq, :gt]
      assert DateTime.compare(fetched_user.authenticated_at, after_token) in [:eq, :lt]
    end

    test "preserves an existing authenticated_at when generating refresh tokens" do
      authenticated_at = ~U[2026-05-14 12:00:00Z]

      user =
        Repo.insert!(%User{sub: "refresh-user", name: "Refresh User"})
        |> Map.put(:authenticated_at, authenticated_at)

      token = Accounts.generate_user_refresh_token(user)

      assert {%User{} = fetched_user, inserted_at} = Accounts.get_user_by_refresh_token(token)
      assert fetched_user.id == user.id
      assert fetched_user.authenticated_at == authenticated_at
      assert is_struct(inserted_at, DateTime)
    end
  end

  describe "mobile auth handoff codes" do
    test "creates an encrypted Phoenix.Token code backed by a single-use UserToken nonce" do
      user = Repo.insert!(%User{sub: "mobile-user", name: "Mobile User"})
      {verifier, challenge} = pkce_pair()

      {:ok, code} =
        Accounts.create_mobile_auth_code(user, %{
          code_challenge: challenge,
          redirect_uri: "sonnet://auth/callback"
        })

      # Token is encrypted (opaque) and backed by a single mobile_code row in users_tokens
      refute String.contains?(code, challenge)
      refute String.contains?(code, "sonnet://auth/callback")
      assert [%UserToken{context: "mobile_code", user_id: user_id}] = mobile_code_rows()
      assert user_id == user.id

      assert {:ok, consumed_user} =
               Accounts.consume_mobile_auth_code(code, verifier, "sonnet://auth/callback")

      assert consumed_user.id == user.id
      assert mobile_code_rows() == []

      # Replay fails
      assert {:error, :invalid_grant} =
               Accounts.consume_mobile_auth_code(code, verifier, "sonnet://auth/callback")
    end

    test "burns the nonce immediately on wrong PKCE code_verifier" do
      user = Repo.insert!(%User{sub: "mobile-pkce-user", name: "Mobile User"})
      {verifier, challenge} = pkce_pair()
      {wrong_verifier, _} = pkce_pair()

      {:ok, code} =
        Accounts.create_mobile_auth_code(user, %{
          code_challenge: challenge,
          redirect_uri: "sonnet://auth/callback"
        })

      assert {:error, :invalid_grant} =
               Accounts.consume_mobile_auth_code(code, wrong_verifier, "sonnet://auth/callback")

      assert mobile_code_rows() == []

      # Even the real verifier cannot redeem it afterwards
      assert {:error, :invalid_grant} =
               Accounts.consume_mobile_auth_code(code, verifier, "sonnet://auth/callback")
    end

    test "burns the nonce immediately on wrong redirect_uri" do
      user = Repo.insert!(%User{sub: "mobile-uri-user", name: "Mobile User"})
      {verifier, challenge} = pkce_pair()

      {:ok, code} =
        Accounts.create_mobile_auth_code(user, %{
          code_challenge: challenge,
          redirect_uri: "sonnet://auth/callback"
        })

      assert {:error, :invalid_grant} =
               Accounts.consume_mobile_auth_code(code, verifier, "sonnet://other/callback")

      assert mobile_code_rows() == []

      assert {:error, :invalid_grant} =
               Accounts.consume_mobile_auth_code(code, verifier, "sonnet://auth/callback")
    end

    test "rejects expired and tampered Phoenix.Token codes" do
      user = Repo.insert!(%User{sub: "mobile-exp-user", name: "Mobile User"})
      {verifier, challenge} = pkce_pair()

      {:ok, expired_code} =
        Accounts.create_mobile_auth_code(
          user,
          %{code_challenge: challenge, redirect_uri: "sonnet://auth/callback"},
          signed_at: System.system_time(:second) - 120
        )

      assert {:error, :invalid_grant} =
               Accounts.consume_mobile_auth_code(expired_code, verifier, "sonnet://auth/callback")

      assert {:error, :invalid_grant} =
               Accounts.consume_mobile_auth_code(
                 expired_code <> "tampered",
                 verifier,
                 "sonnet://auth/callback"
               )
    end

    test "allows at most one winner under concurrent redemption attempts" do
      user = Repo.insert!(%User{sub: "mobile-race-user", name: "Mobile User"})
      {verifier, challenge} = pkce_pair()

      {:ok, code} =
        Accounts.create_mobile_auth_code(user, %{
          code_challenge: challenge,
          redirect_uri: "sonnet://auth/callback"
        })

      results =
        1..6
        |> Enum.map(fn _ ->
          Task.async(fn ->
            Accounts.consume_mobile_auth_code(code, verifier, "sonnet://auth/callback")
          end)
        end)
        |> Enum.map(&Task.await/1)

      assert length(Enum.filter(results, &match?({:ok, _}, &1))) == 1
      assert length(Enum.filter(results, &(&1 == {:error, :invalid_grant}))) == 5
    end
  end
end
