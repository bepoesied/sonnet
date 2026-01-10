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

  alias Ecto.Multi

  def create_media_asset!(s3_key) do
    Repo.insert!(MediaAsset.changeset(%MediaAsset{}, %{s3_key: s3_key}),
      on_conflict: [set: [s3_key: s3_key]],
      conflict_target: :s3_key,
      returning: true
    )
  end

  def delete_media_asset_by_s3_key(s3_key) do
    from(m in MediaAsset, where: m.s3_key == ^s3_key)
    |> Repo.delete_all()
  end

  def ingest_multi_file!(
        s3_keys,
        original_filenames,
        media_assets,
        durations,
        book_metadata
      ) do
    title = book_metadata["title"] || "Untitled Book"
    author = book_metadata["author"]
    narrator = book_metadata["narrator"]
    description = book_metadata["description"]

    Multi.new()
    |> Multi.insert(
      :book,
      Book.changeset(%Book{}, %{
        title: title,
        author: author,
        narrator: narrator,
        description: description
      })
    )
    |> Multi.merge(fn %{book: book} ->
      files_data =
        Enum.zip([s3_keys, original_filenames, media_assets, durations])
        |> Enum.with_index()

      Enum.reduce(files_data, Multi.new(), fn {{_s3_key, original_filename, media_asset,
                                                duration_ms}, index},
                                              multi ->
        name = "insert_chapter_#{index}"

        cumulative_start =
          files_data
          |> Enum.take(index)
          |> Enum.map(fn {{_, _, _, d}, _} -> d end)
          |> Enum.sum()

        cumulative_end = cumulative_start + duration_ms

        chapter_changeset =
          Chapter.changeset(%Chapter{}, %{
            position: index,
            title: Path.rootname(original_filename) || "Chapter #{index + 1}",
            start_ms: cumulative_start,
            end_ms: cumulative_end,
            duration_ms: duration_ms,
            book_id: book.id,
            media_asset_id: media_asset.id
          })

        Multi.insert(multi, name, chapter_changeset)
      end)
    end)
    |> Repo.transaction()
  end

  def ingest_segmented!(
        segments_data,
        book_metadata,
        cover_s3_key \\ nil
      ) do
    title = book_metadata["title"] || "Untitled Book"
    author = book_metadata["author"]
    narrator = book_metadata["narrator"]
    description = book_metadata["description"]

    Multi.new()
    |> Multi.insert(
      :book,
      Book.changeset(%Book{}, %{
        title: title,
        author: author,
        narrator: narrator,
        description: description,
        cover_s3_key: cover_s3_key
      })
    )
    |> Multi.merge(fn %{book: book} ->
      segments_data
      |> Enum.with_index()
      |> Enum.reduce(Multi.new(), fn {%{s3_key: s3_key, title: title, duration_ms: duration_ms},
                                      index},
                                     multi ->
        asset_name = "get_or_insert_media_asset_#{index}"
        chapter_name = "insert_chapter_#{index}"

        Multi.insert(
          multi,
          asset_name,
          MediaAsset.changeset(%MediaAsset{}, %{s3_key: s3_key}),
          on_conflict: [set: [s3_key: s3_key]],
          conflict_target: :s3_key,
          returning: true
        )
        |> Multi.run(chapter_name, fn repo, %{^asset_name => asset} ->
          chapter_title = title || "Chapter #{index + 1}"

          cumulative_start =
            segments_data
            |> Enum.take(index)
            |> Enum.map(& &1.duration_ms)
            |> Enum.sum()

          cumulative_end = cumulative_start + duration_ms

          chapter_changeset =
            Chapter.changeset(%Chapter{}, %{
              position: index,
              title: chapter_title,
              start_ms: cumulative_start,
              end_ms: cumulative_end,
              duration_ms: duration_ms,
              book_id: book.id,
              media_asset_id: asset.id
            })

          repo.insert(chapter_changeset)
        end)
      end)
    end)
    |> Repo.transaction()
  end

  def list_books(user_id \\ nil) do
    query =
      if user_id do
        from b in Book,
          left_join: lp in ListenProgress,
          on: lp.book_id == b.id and lp.user_id == ^user_id,
          select_merge: %{is_completed: fragment("coalesce(?, false)", lp.is_completed)},
          order_by: [desc_nulls_last: lp.updated_at]
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
    Sonnet.Storage.presigned_get_url(s3_key)
  end

  def update_book(id, attrs) do
    id
    |> get_book!()
    |> Book.changeset(attrs)
    |> Repo.update()
    |> case do
      {:ok, book} ->
        broadcast_books_updated()
        {:ok, book}

      {:error, changeset} ->
        {:error, changeset}
    end
  end
end
