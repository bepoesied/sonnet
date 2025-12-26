defmodule Sonnet.Repo.Migrations.AllowZeroDurationChapters do
  use Ecto.Migration

  def up do
    execute("ALTER TABLE chapters DROP CONSTRAINT IF EXISTS chapter_duration_must_be_positive")

    execute("""
    ALTER TABLE chapters
    ADD CONSTRAINT chapter_duration_valid
    CHECK (end_ms > start_ms OR (end_ms = 0 AND start_ms = 0))
    """)
  end

  def down do
    execute("ALTER TABLE chapters DROP CONSTRAINT IF EXISTS chapter_duration_valid")

    execute("""
    ALTER TABLE chapters
    ADD CONSTRAINT chapter_duration_must_be_positive
    CHECK (end_ms > start_ms)
    """)
  end
end
