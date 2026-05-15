defmodule SonnetWeb.PlayerController do
  use SonnetWeb, :controller

  alias Sonnet.Library
  alias SonnetWeb.BookSerializer

  def show(conn, %{"book_id" => book_id}) do
    user = conn.assigns.current_scope.user

    with {:ok, book_id} <- parse_id(book_id),
         book when not is_nil(book) <- Library.get_book_with_status(book_id, user.id) do
      render_player(conn, book, user)
    else
      _ -> not_found(conn)
    end
  end

  defp render_player(conn, book, user) do
    progress = Library.get_listen_progress(user.id, book.id)
    book_data = BookSerializer.player_detail(book, progress)

    render(conn, :show, book_data: book_data, page_title: "#{book.title} - Player")
  end

  defp parse_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> {:ok, integer}
      _ -> :error
    end
  end

  defp parse_id(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp parse_id(_value), do: :error

  defp not_found(conn) do
    conn
    |> put_status(:not_found)
    |> put_view(html: SonnetWeb.ErrorHTML)
    |> render(:"404")
  end
end
