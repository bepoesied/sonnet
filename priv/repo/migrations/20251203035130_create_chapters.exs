defmodule Sonnet.Repo.Migrations.CreateChapters do
  use Ecto.Migration

  def change do
    create table(:chapters) do
      add :title, :string, null: false
      add :start_ms, :integer, null: false
      add :end_ms, :integer, null: false
      add :position, :integer, null: false
      add :book_id, references(:books, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:chapters, [:book_id])
    create unique_index(:chapters, [:book_id, :position])

    create constraint(:chapters, :start_ms_must_be_positive, check: "start_ms >= 0")
    create constraint(:chapters, :end_ms_must_be_positive, check: "end_ms >= 0")
    create constraint(:chapters, :chapter_duration_must_be_positive, check: "end_ms > start_ms")
  end
end
