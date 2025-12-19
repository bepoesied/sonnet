defmodule Sonnet.Repo.Migrations.CreateMediaAssets do
  use Ecto.Migration

  def change do
    create table(:media_assets) do
      add :s3_key, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:media_assets, [:s3_key])
  end
end
