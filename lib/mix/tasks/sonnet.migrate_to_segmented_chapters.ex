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

    migrate_books(dry_run?)
  end

  defp migrate_books(dry_run?) do
    alias Sonnet.Library
    alias Sonnet.Repo
    alias Sonnet.Library.Book

    IO.puts("Finding books that need migration...")

    books_to_migrate = Library.find_books_needing_migration()

    case length(books_to_migrate) do
      0 ->
        IO.puts("✓ No books found that need migration")

      count ->
        IO.puts("Found #{count} books to migrate:")
        IO.puts("")

        Enum.each(books_to_migrate, fn %{book_id: book_id, media_asset_id: _media_asset_id} ->
          book = Repo.get!(Book, book_id)
          IO.puts("  - [#{book_id}] #{book.title}")
        end)

        IO.puts("")

        if dry_run? do
          IO.puts("Dry run complete. Run without --dry-run to migrate.")
        else
          IO.puts("Starting migration...")
          IO.puts("")

          Enum.each(books_to_migrate, fn %{book_id: book_id, media_asset_id: media_asset_id} ->
            migrate_book(book_id, media_asset_id)
          end)

          IO.puts("")
          IO.puts("✓ Migration complete!")
          IO.puts("")
          IO.puts("Note: Original m4b files have been kept in S3.")
          IO.puts("      You can clean them up later with a separate task.")
        end
    end
  end

  defp migrate_book(book_id, media_asset_id) do
    alias Sonnet.Library
    alias Sonnet.Repo
    alias Sonnet.Library.Book

    book = Repo.get!(Book, book_id)

    IO.write("  Migrating [#{book_id}] #{book.title}... ")

    try do
      Library.segment_book!(book_id, media_asset_id)

      IO.write("✓ Segmented")
      IO.puts("")

      :ok
    rescue
      e ->
        IO.write("✗ Failed: #{inspect(e)}")
        IO.puts("")

        {:error, e}
    end
  end
end
