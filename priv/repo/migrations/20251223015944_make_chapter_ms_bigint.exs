defmodule Sonnet.Repo.Migrations.MakeChapterMsBigint do
  use Ecto.Migration

  def change do
    alter table(:chapters) do
      modify :start_ms, :bigint
      modify :end_ms, :bigint
    end
  end
end
