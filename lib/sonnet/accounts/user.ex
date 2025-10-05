defmodule Sonnet.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field :sub, :string
    field :name, :string
    field :avatar_url, :string
    field :authenticated_at, :utc_datetime, virtual: true

    timestamps(type: :utc_datetime)
  end

  def oidc_changeset(user, attrs, _opts \\ []) do
    user
    |> cast(attrs, [:sub, :name, :avatar_url])
  end
end
