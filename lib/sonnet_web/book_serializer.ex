defmodule SonnetWeb.BookSerializer do
  alias Sonnet.Library

  def api_summary(book, opts \\ []) do
    %{
      id: book.id,
      title: book.title,
      author: book.author,
      narrator: book.narrator,
      description: book.description,
      cover_url: cover_url(book, opts),
      is_completed: book.is_completed
    }
  end

  def api_detail(book, progress \\ nil, opts \\ []) do
    book
    |> api_summary(opts)
    |> Map.put(:chapters, Enum.map(book.chapters, &player_chapter(&1, opts)))
    |> Map.put(:progress, progress(progress))
  end

  def player_detail(book, progress, opts \\ []) do
    book
    |> api_summary(opts)
    |> Map.put(:chapters, Enum.map(book.chapters, &player_chapter(&1, opts)))
    |> Map.put(:progress, player_progress(progress))
  end

  def progress(nil) do
    %{
      chapter_id: nil,
      offset_ms: 0,
      updated_at: nil,
      is_completed: false
    }
  end

  def progress(progress) do
    %{
      chapter_id: progress.chapter_id,
      offset_ms: progress.offset_ms,
      updated_at: progress.updated_at,
      is_completed: progress.is_completed
    }
  end

  defp api_chapter(chapter) do
    %{
      id: chapter.id,
      title: chapter.title,
      position: chapter.position,
      start_ms: chapter.start_ms,
      end_ms: chapter.end_ms,
      duration_ms: chapter.duration_ms,
      media_asset_id: chapter.media_asset_id
    }
  end

  defp player_chapter(chapter, opts) do
    chapter
    |> api_chapter()
    |> Map.put(:audio_url, url_for(chapter.media_asset.s3_key, opts))
  end

  defp player_progress(nil), do: nil

  defp player_progress(progress) do
    %{
      chapter_id: progress.chapter_id,
      offset_ms: progress.offset_ms,
      updated_at: progress.updated_at
    }
  end

  defp cover_url(%{cover_s3_key: nil}, _opts), do: nil
  defp cover_url(book, opts), do: url_for(book.cover_s3_key, opts)

  defp url_for(s3_key, opts) do
    url_fun = Keyword.get(opts, :url_fun, &Library.presigned_url/1)
    url_fun.(s3_key)
  end
end
