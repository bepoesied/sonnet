defmodule Sonnet.Repo.Migrations.CreateBooks do
  use Ecto.Migration

  def change do
    create table(:books) do
      add :name, :string
      add :bucket, :string
      add :path, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:books, [:name])
  end
end
