defmodule Sonnet.Library do
  import Ecto.Query, warn: false

  @topic "library"

  def subscribe do
    Phoenix.PubSub.subscribe(Sonnet.PubSub, @topic)
  end

  def broadcast_books_updated do
    Phoenix.PubSub.broadcast(Sonnet.PubSub, @topic, :books_updated)
  end

  alias Sonnet.Repo
  alias Sonnet.Library.Chapter
  alias Sonnet.Library.Book
  alias Sonnet.Library.MediaAsset
  alias Sonnet.Library.ListenProgress

  def create_media_asset!(s3_key) do
    Repo.insert!(MediaAsset.changeset(%MediaAsset{}, %{s3_key: s3_key}),
      on_conflict: :nothing,
      conflict_target: :s3_key,
      returning: true
    )
  end

  def ingest_probe!(
        %{"chapters" => chapters, "format" => format},
        media_asset_id,
        cover_s3_key \\ nil
      ) do
    book =
      Book.changeset(%Book{}, %{
        title: format["tags"]["title"],
        author: Map.get(format["tags"], "author"),
        narrator: Map.get(format["tags"], "artist"),
        description: Map.get(format["tags"], "description"),
        cover_s3_key: cover_s3_key
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

  def list_books(user_id \\ nil) do
    query =
      if user_id do
        from b in Book,
          left_join: lp in ListenProgress,
          on: lp.book_id == b.id and lp.user_id == ^user_id,
          select_merge: %{is_completed: fragment("coalesce(?, false)", lp.is_completed)}
      else
        Book
      end

    Repo.all(query)
  end

  def get_book_with_status!(id, user_id) do
    chapters_query = from c in Chapter, order_by: c.position, preload: [:media_asset]

    from(b in Book,
      where: b.id == ^id,
      left_join: lp in ListenProgress,
      on: lp.book_id == b.id and lp.user_id == ^user_id,
      select_merge: %{is_completed: fragment("coalesce(?, false)", lp.is_completed)}
    )
    |> Repo.one!()
    |> Repo.preload(chapters: chapters_query)
  end

  def get_book!(id) do
    chapters_query = from c in Chapter, order_by: c.position, preload: [:media_asset]
    Repo.get!(Book, id) |> Repo.preload(chapters: chapters_query)
  end

  def get_listen_progress(user_id, book_id) do
    Repo.get_by(ListenProgress, user_id: user_id, book_id: book_id)
    |> Repo.preload(chapter: [:media_asset])
  end

  def save_listen_progress(user_id, book_id, chapter_id, offset_ms, is_completed \\ nil) do
    attrs = %{
      user_id: user_id,
      book_id: book_id,
      chapter_id: chapter_id,
      offset_ms: offset_ms
    }

    attrs = if is_nil(is_completed), do: attrs, else: Map.put(attrs, :is_completed, is_completed)

    %ListenProgress{}
    |> ListenProgress.changeset(attrs)
    |> Repo.insert(
      on_conflict: [
        set:
          Enum.map(attrs, fn {k, v} -> {k, v} end) ++
            [{:updated_at, DateTime.utc_now()}]
      ],
      conflict_target: [:user_id, :book_id]
    )
  end

  def mark_book_complete(user_id, book_id, chapter_id) do
    save_listen_progress(user_id, book_id, chapter_id, 0, true)
  end

  def mark_book_incomplete(user_id, book_id) do
    case get_listen_progress(user_id, book_id) do
      nil ->
        {:ok, nil}

      progress ->
        save_listen_progress(user_id, book_id, progress.chapter_id, progress.offset_ms, false)
    end
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
