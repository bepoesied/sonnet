defmodule Sonnet.Library do
  alias Sonnet.Repo
  alias Sonnet.Library.Chapter
  alias Sonnet.Library.Book
  alias Sonnet.Library.MediaAsset

  def create_media_asset!(s3_key) do
    Repo.insert!(MediaAsset.changeset(%MediaAsset{}, %{s3_key: s3_key}),
      on_conflict: :nothing,
      conflict_target: s3_key,
      returning: true
    )
  end

  def ingest_probe!(%{"chapters" => chapters, "format" => format}, media_asset_id) do
    book =
      Book.changeset(%Book{}, %{
        title: format["tags"]["title"],
        author: Map.get(format["tags"], "author"),
        narrator: Map.get(format["tags"], "artist"),
        description: Map.get(format["tags"], "description")
      })

    {:ok, book} = Repo.insert(book)

    {:ok, _chapters} =
      chapters
      |> Enum.with_index()
      |> Enum.map(fn {chapter, index} ->
        chapter = handle_chapter(book.id, media_asset_id, index, chapter)
        name = "insert_chapter_#{index}"
        {chapter, name}
      end)
      |> Enum.reduce(Ecto.Multi.new(), fn {chapter, name}, multi ->
        Ecto.Multi.insert(multi, name, chapter)
      end)
      |> Repo.transact()
  end

  def list_books do
    Repo.all(Book)
  end

  def get_book!(id) do
    Repo.get!(Book, id) |> Repo.preload(chapters: :media_asset)
  end

  def presigned_url(nil), do: nil

  def presigned_url(s3_key) do
    config = ExAws.Config.new(:s3)
    bucket = Application.get_env(:sonnet, :ingest_bucket)

    {:ok, url} = ExAws.S3.presigned_url(config, :get, bucket, s3_key, expires_in: 3600)
    url
  end

  defp handle_chapter(book_id, media_asset_id, index, chapter) do
    Chapter.changeset(%Chapter{}, %{
      position: index,
      title: Map.get(chapter["tags"], "title"),
      start_ms: chapter["start"],
      end_ms: chapter["end"],
      book_id: book_id,
      media_asset_id: media_asset_id
    })
  end
end
