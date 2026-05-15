defmodule Sonnet.AccountsTest do
  use Sonnet.DataCase, async: true

  alias Sonnet.Accounts
  alias Sonnet.Accounts.User

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
end
