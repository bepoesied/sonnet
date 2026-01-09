defmodule Mix.Tasks.Sonnet.MigrateToSegmentedChapters do
  @moduledoc """
  Migrates existing audiobooks from single-file format (m4b) to segmented MP3 chapters.

  This task finds all books where chapters share the same media asset (indicating
  a single large file) and segments them into individual chapter MP3 files.

  ## Examples

      # Dry run - shows what will be migrated without actually doing it
      mix sonnet.migrate_to_segmented_chapters --dry-run

      # Full migration
      mix sonnet.migrate_to_segmented_chapters

  ## Options

    * `--dry-run` - Print books to be migrated without processing
  """

  use Mix.Task

  @shortdoc "Migrates books to segmented chapter format"

  @impl true
  def run(args) do
    Application.put_env(:sonnet, :start_workers, false)
    {:ok, _} = Application.ensure_all_started(:sonnet)

    dry_run? = "--dry-run" in args

    Sonnet.Release.migrate_books(dry_run?)
  end
end
