defmodule SonnetWeb.API.BookController do
  use SonnetWeb, :controller

  alias Sonnet.Library

  def index(conn, _params) do
    user = conn.assigns.current_scope.user
    books = Library.list_books(user.id)

    books_json =
      Enum.map(books, fn book ->
        %{
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
          is_completed: book.is_completed
        }
      end)

    json(conn, books_json)
  end

  def show(conn, %{"id" => id}) do
    user = conn.assigns.current_scope.user
    book = Library.get_book_with_status!(String.to_integer(id), user.id)

    chapters_json =
      Enum.map(book.chapters, fn chapter ->
        %{
          id: chapter.id,
          title: chapter.title,
          position: chapter.position,
          start_ms: chapter.start_ms,
          end_ms: chapter.end_ms,
          duration_ms: chapter.duration_ms,
          media_asset_id: chapter.media_asset_id
        }
      end)

    json(conn, %{
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
      chapters: chapters_json,
      is_completed: book.is_completed
    })
  end

  def progress(conn, %{"id" => book_id}) do
    user = conn.assigns.current_scope.user
    progress = Library.get_listen_progress(user.id, String.to_integer(book_id))

    data =
      if progress do
        %{
          chapter_id: progress.chapter_id,
          offset_ms: progress.offset_ms,
          updated_at: progress.updated_at,
          is_completed: progress.is_completed
        }
      else
        %{
          chapter_id: nil,
          offset_ms: 0,
          updated_at: nil,
          is_completed: false
        }
      end

    json(conn, data)
  end

  def update_progress(conn, %{"id" => book_id} = params) do
    user = conn.assigns.current_scope.user

    chapter_id = Map.get(params, "chapter_id")
    offset_ms = Map.get(params, "offset_ms", 0)

    Library.save_listen_progress(
      user.id,
      to_int(book_id),
      to_int(chapter_id),
      to_int(offset_ms)
    )

    send_resp(conn, :no_content, "")
  end

  def complete(conn, %{"id" => book_id} = params) do
    user = conn.assigns.current_scope.user

    chapter_id =
      Map.get(params, "chapter_id") ||
        Library.get_book!(to_int(book_id)).chapters |> List.first() |> Map.get(:id)

    Library.mark_book_complete(user.id, to_int(book_id), to_int(chapter_id))

    send_resp(conn, :no_content, "")
  end

  def incomplete(conn, %{"id" => book_id}) do
    user = conn.assigns.current_scope.user
    Library.mark_book_incomplete(user.id, to_int(book_id))

    send_resp(conn, :no_content, "")
  end

  defp to_int(nil), do: nil
  defp to_int(val) when is_integer(val), do: val
  defp to_int(val) when is_binary(val), do: String.to_integer(val)
end
