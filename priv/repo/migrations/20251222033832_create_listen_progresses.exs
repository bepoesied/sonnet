defmodule Sonnet.Repo.Migrations.CreateListenProgresses do
  use Ecto.Migration

  def change do
    create table(:listen_progresses) do
      add :offset_ms, :integer, null: false
      add :book_id, references(:books, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :chapter_id, references(:chapters, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:listen_progresses, [:user_id])
    create index(:listen_progresses, [:book_id])
    create index(:listen_progresses, [:chapter_id])
    create unique_index(:listen_progresses, [:user_id, :book_id])
  end
end
