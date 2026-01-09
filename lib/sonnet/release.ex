defmodule Sonnet.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed.
  """
  @app :sonnet

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  def migrate_to_segmented_chapters do
    load_app()
    migrate_books(false)
  end

  def migrate_to_segmented_chapters_dry_run do
    load_app()
    migrate_books(true)
  end

  def migrate_books(dry_run?) do
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
          IO.puts("Dry run complete. Run without dry-run to migrate.")
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

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    # Many platforms require SSL when connecting to the database
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
