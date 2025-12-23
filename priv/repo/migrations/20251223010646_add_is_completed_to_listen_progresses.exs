defmodule Sonnet.Repo.Migrations.AddIsCompletedToListenProgresses do
  use Ecto.Migration

  def change do
    alter table(:listen_progresses) do
      add :is_completed, :boolean, default: false, null: false
    end
  end
end
