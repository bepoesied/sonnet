defmodule SonnetWeb.API.BookControllerTest do
  use SonnetWeb.ConnCase, async: true

  alias Sonnet.Accounts
  alias Sonnet.Library
  alias Sonnet.Library.Book
  alias Sonnet.Library.Chapter
  alias Sonnet.Repo

  describe "show/2" do
    test "returns 400 for malformed book IDs", %{conn: conn} do
      conn = get(authenticated_conn(conn), ~p"/api/books/not-an-id")

      assert json_response(conn, 400) == %{"error" => "Invalid book ID"}
    end

    test "returns 404 for missing books", %{conn: conn} do
      conn = get(authenticated_conn(conn), ~p"/api/books/999999")

      assert json_response(conn, 404) == %{"error" => "Book not found"}
    end
  end

  describe "update_progress/2" do
    test "returns 422 for malformed progress payloads", %{conn: conn} do
      {book, _chapter} = book_with_chapter_fixture("Payload Book")

      conn =
        authenticated_conn(conn)
        |> put(~p"/api/books/#{book.id}/progress", %{chapter_id: "bad", offset_ms: 0})

      assert json_response(conn, 422) == %{"error" => "Invalid progress payload"}
    end

    test "returns 422 when the chapter belongs to another book", %{conn: conn} do
      {book, _chapter} = book_with_chapter_fixture("Progress Book")
      {_other_book, other_chapter} = book_with_chapter_fixture("Other Book")

      conn =
        authenticated_conn(conn)
        |> put(~p"/api/books/#{book.id}/progress", %{chapter_id: other_chapter.id, offset_ms: 0})

      assert json_response(conn, 422) == %{"error" => "Chapter not found"}
    end

    test "returns 422 for negative offsets", %{conn: conn} do
      {book, chapter} = book_with_chapter_fixture("Negative Offset Book")

      conn =
        authenticated_conn(conn)
        |> put(~p"/api/books/#{book.id}/progress", %{chapter_id: chapter.id, offset_ms: -1})

      assert json_response(conn, 422) == %{"error" => "Invalid progress payload"}
    end
  end

  describe "complete/2" do
    test "returns 422 when a book has no chapters", %{conn: conn} do
      book = book_fixture("Empty Book")

      conn = put(authenticated_conn(conn), ~p"/api/books/#{book.id}/complete", %{})

      assert json_response(conn, 422) == %{"error" => "Book has no chapters"}
    end
  end

  defp authenticated_conn(conn) do
    user = user_fixture()
    token = Accounts.generate_user_session_token(user)

    conn
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", "Bearer #{Base.url_encode64(token, padding: false)}")
  end

  defp user_fixture do
    {:ok, user} = Accounts.register_user(%{sub: Ecto.UUID.generate(), name: "Test User"})
    user
  end

  defp book_fixture(title) do
    {:ok, book} =
      %Book{}
      |> Book.changeset(%{title: title})
      |> Repo.insert()

    book
  end

  defp book_with_chapter_fixture(title) do
    book = book_fixture(title)
    media_asset = Library.create_media_asset!("books/#{Ecto.UUID.generate()}.mp3")

    {:ok, chapter} =
      %Chapter{}
      |> Chapter.changeset(%{
        title: "Chapter 1",
        position: 0,
        start_ms: 0,
        end_ms: 1_000,
        duration_ms: 1_000,
        book_id: book.id,
        media_asset_id: media_asset.id
      })
      |> Repo.insert()

    {book, chapter}
  end
end
