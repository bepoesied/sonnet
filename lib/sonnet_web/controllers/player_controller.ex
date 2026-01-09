defmodule SonnetWeb.PlayerController do
  use SonnetWeb, :controller

  alias Sonnet.Library

  def show(conn, %{"book_id" => book_id}) do
    user = conn.assigns.current_scope.user
    book = Library.get_book_with_status!(String.to_integer(book_id), user.id)

    chapters_with_urls =
      Enum.map(book.chapters, fn chapter ->
        %{
          id: chapter.id,
          title: chapter.title,
          position: chapter.position,
          start_ms: chapter.start_ms,
          end_ms: chapter.end_ms,
          duration_ms: chapter.duration_ms,
          media_asset_id: chapter.media_asset_id,
          audio_url: Library.presigned_url(chapter.media_asset.s3_key)
        }
      end)

    progress = Library.get_listen_progress(user.id, book.id)

    book_data = %{
      id: book.id,
      title: book.title,
      author: book.author,
      narrator: book.narrator,
      description: book.description,
      cover_url:
        if(book.cover_s3_key,
          do: Library.presigned_url(book.cover_s3_key),
          else: nil
        ),
      chapters: chapters_with_urls,
      is_completed: book.is_completed,
      progress:
        if(progress,
          do: %{
            chapter_id: progress.chapter_id,
            offset_ms: progress.offset_ms,
            updated_at: progress.updated_at
          },
          else: nil
        )
    }

    render(conn, :show, book_data: book_data, page_title: "#{book.title} - Player")
  end
end
