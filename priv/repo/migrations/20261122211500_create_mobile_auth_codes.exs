defmodule Sonnet.Repo.Migrations.CreateMobileAuthCodes do
  use Ecto.Migration

  def change do
    create table(:mobile_auth_codes) do
      add :code_hash, :binary, null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :code_challenge, :string, null: false
      add :redirect_uri, :string, null: false
      add :expires_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:mobile_auth_codes, [:code_hash])
    create index(:mobile_auth_codes, [:user_id])
    create index(:mobile_auth_codes, [:expires_at])
  end
end
