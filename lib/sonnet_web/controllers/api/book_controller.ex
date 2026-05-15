defmodule SonnetWeb.API.BookController do
  use SonnetWeb, :controller

  alias Sonnet.Library
  alias SonnetWeb.BookSerializer

  def index(conn, _params) do
    user = conn.assigns.current_scope.user
    books = Library.list_books(user.id)

    books_json = Enum.map(books, &BookSerializer.api_summary/1)

    json(conn, books_json)
  end

  def show(conn, %{"id" => id}) do
    user = conn.assigns.current_scope.user

    with {:ok, book_id} <- parse_id(id),
         book when not is_nil(book) <- Library.get_book_with_status(book_id, user.id) do
      render_book(conn, book)
    else
      :error -> error(conn, :bad_request, "Invalid book ID")
      nil -> error(conn, :not_found, "Book not found")
    end
  end

  def progress(conn, %{"id" => book_id}) do
    user = conn.assigns.current_scope.user

    with {:ok, book_id} <- parse_id(book_id),
         book when not is_nil(book) <- Library.get_book(book_id) do
      json(conn, BookSerializer.progress(Library.get_listen_progress(user.id, book.id)))
    else
      :error -> error(conn, :bad_request, "Invalid book ID")
      nil -> error(conn, :not_found, "Book not found")
    end
  end

  def update_progress(conn, %{"id" => book_id} = params) do
    user = conn.assigns.current_scope.user

    with {:ok, book_id} <- parse_id(book_id),
         book when not is_nil(book) <- Library.get_book(book_id),
         {:ok, chapter_id} <- parse_required_int(Map.get(params, "chapter_id")),
         {:ok, offset_ms} <- parse_non_negative_int(Map.get(params, "offset_ms", 0)),
         {:ok, updated_at} <- parse_optional_datetime(Map.get(params, "updated_at")),
         {:ok, _progress} <-
           Library.save_listen_progress(user.id, book.id, chapter_id, offset_ms, nil, updated_at) do
      send_resp(conn, :no_content, "")
    else
      :error ->
        error(conn, :bad_request, "Invalid book ID")

      nil ->
        error(conn, :not_found, "Book not found")

      {:error, :invalid_integer} ->
        error(conn, :unprocessable_entity, "Invalid progress payload")

      {:error, :invalid_datetime} ->
        error(conn, :unprocessable_entity, "Invalid progress payload")

      {:error, :chapter_not_found} ->
        error(conn, :unprocessable_entity, "Chapter not found")

      {:error, %Ecto.Changeset{}} ->
        error(conn, :unprocessable_entity, "Invalid progress payload")
    end
  end

  def complete(conn, %{"id" => book_id} = params) do
    user = conn.assigns.current_scope.user

    with {:ok, book_id} <- parse_id(book_id),
         book when not is_nil(book) <- Library.get_book(book_id),
         {:ok, chapter_id} <- completion_chapter_id(book, params),
         {:ok, _progress} <- Library.mark_book_complete(user.id, book.id, chapter_id) do
      send_resp(conn, :no_content, "")
    else
      :error ->
        error(conn, :bad_request, "Invalid book ID")

      nil ->
        error(conn, :not_found, "Book not found")

      {:error, :invalid_integer} ->
        error(conn, :unprocessable_entity, "Invalid progress payload")

      {:error, :no_chapters} ->
        error(conn, :unprocessable_entity, "Book has no chapters")

      {:error, :chapter_not_found} ->
        error(conn, :unprocessable_entity, "Chapter not found")

      {:error, %Ecto.Changeset{}} ->
        error(conn, :unprocessable_entity, "Invalid progress payload")
    end
  end

  def incomplete(conn, %{"id" => book_id}) do
    user = conn.assigns.current_scope.user

    with {:ok, book_id} <- parse_id(book_id),
         book when not is_nil(book) <- Library.get_book(book_id),
         {:ok, _progress} <- Library.mark_book_incomplete(user.id, book.id) do
      send_resp(conn, :no_content, "")
    else
      :error ->
        error(conn, :bad_request, "Invalid book ID")

      nil ->
        error(conn, :not_found, "Book not found")

      {:error, %Ecto.Changeset{}} ->
        error(conn, :unprocessable_entity, "Invalid progress payload")

      {:error, :chapter_not_found} ->
        error(conn, :unprocessable_entity, "Chapter not found")
    end
  end

  defp render_book(conn, book) do
    user = conn.assigns.current_scope.user
    progress = Library.get_listen_progress(user.id, book.id)

    json(conn, BookSerializer.api_detail(book, progress))
  end

  defp completion_chapter_id(book, params) do
    case Map.fetch(params, "chapter_id") do
      {:ok, chapter_id} -> parse_required_int(chapter_id)
      :error -> first_chapter_id(book)
    end
  end

  defp first_chapter_id(book) do
    case List.first(book.chapters) do
      nil -> {:error, :no_chapters}
      chapter -> {:ok, chapter.id}
    end
  end

  defp parse_id(value) do
    with {:ok, integer} <- parse_required_int(value), true <- integer > 0 do
      {:ok, integer}
    else
      _ -> :error
    end
  end

  defp parse_non_negative_int(value) do
    with {:ok, integer} <- parse_required_int(value), true <- integer >= 0 do
      {:ok, integer}
    else
      _ -> {:error, :invalid_integer}
    end
  end

  defp parse_required_int(value) when is_integer(value), do: {:ok, value}

  defp parse_required_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> {:ok, integer}
      _ -> {:error, :invalid_integer}
    end
  end

  defp parse_required_int(_value), do: {:error, :invalid_integer}

  defp parse_optional_datetime(nil), do: {:ok, nil}

  defp parse_optional_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      {:error, _reason} -> {:error, :invalid_datetime}
    end
  end

  defp parse_optional_datetime(_value), do: {:error, :invalid_datetime}

  defp error(conn, status, message) do
    conn
    |> put_status(status)
    |> json(%{error: message})
  end
end
