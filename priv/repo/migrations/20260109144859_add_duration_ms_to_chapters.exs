defmodule Sonnet.Repo.Migrations.AddDurationMsToChapters do
  use Ecto.Migration

  def change do
    alter table(:chapters) do
      add :duration_ms, :integer
    end

    execute "UPDATE chapters SET duration_ms = (end_ms - start_ms)"

    alter table(:chapters) do
      modify :duration_ms, :integer, null: false, default: 0
    end

    create constraint(:chapters, :duration_ms_must_be_positive, check: "duration_ms >= 0")
  end
end
