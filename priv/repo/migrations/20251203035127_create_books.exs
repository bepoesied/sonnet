defmodule Sonnet.Repo.Migrations.CreateBooks do
  use Ecto.Migration

  def change do
    create table(:books) do
      add :title, :string, null: false
      add :author, :string
      add :narrator, :string
      add :description, :text
      add :cover_s3_key, :string

      timestamps(type: :utc_datetime)
    end
  end
end
