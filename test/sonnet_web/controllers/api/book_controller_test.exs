defmodule SonnetWeb.API.BookControllerTest do
  use SonnetWeb.ConnCase, async: true

  alias Sonnet.Accounts
  alias Sonnet.Library
  alias Sonnet.Library.Book
  alias Sonnet.Library.Chapter
  alias Sonnet.Library.ListenProgress
  alias Sonnet.Repo

  describe "authentication" do
    test "returns JSON 401 for unauthenticated API GET requests", %{conn: conn} do
      conn =
        conn
        |> put_req_header("accept", "application/json")
        |> get(~p"/api/books")

      assert json_response(conn, 401) == %{"error" => "Unauthorized"}
    end

    test "returns JSON 401 without audio URLs for unauthenticated API detail requests", %{
      conn: conn
    } do
      {book, _chapter} = book_with_chapter_fixture("Unauthenticated Detail Book")

      conn =
        conn
        |> put_req_header("accept", "application/json")
        |> get(~p"/api/books/#{book.id}")

      assert json_response(conn, 401) == %{"error" => "Unauthorized"}
      refute response(conn, 401) =~ "audio_url"
    end

    test "returns JSON 401 for unauthenticated API write requests", %{conn: conn} do
      {book, chapter} = book_with_chapter_fixture("Unauthenticated Progress Book")

      conn =
        conn
        |> put_req_header("accept", "application/json")
        |> put(~p"/api/books/#{book.id}/progress", %{chapter_id: chapter.id, offset_ms: 123})

      assert json_response(conn, 401) == %{"error" => "Unauthorized"}
    end
  end

  describe "index/2" do
    test "returns books with completion state for the authenticated user", %{conn: conn} do
      user = user_fixture()
      other_user = user_fixture()
      token = Accounts.generate_user_session_token(user)
      {book, chapter} = book_with_chapter_fixture("API List Book")

      assert {:ok, _progress} = Library.mark_book_complete(user.id, book.id, chapter.id)

      assert {:ok, _progress} =
               Library.save_listen_progress(other_user.id, book.id, chapter.id, 100)

      conn =
        conn
        |> authenticated_conn(token)
        |> get(~p"/api/books")

      assert [payload] = json_response(conn, 200)
      assert payload["id"] == book.id
      assert payload["title"] == "API List Book"
      assert payload["is_completed"] == true
      refute Map.has_key?(payload, "chapters")
    end
  end

  describe "show/2" do
    test "returns book details with playback URLs, cover, chapters, and progress", %{conn: conn} do
      user = user_fixture()
      token = Accounts.generate_user_session_token(user)

      {book, chapter} =
        book_with_chapter_fixture("Detail Book", cover_s3_key: "covers/detail.jpg")

      assert {:ok, _progress} = Library.save_listen_progress(user.id, book.id, chapter.id, 321)

      conn =
        conn
        |> authenticated_conn(token)
        |> get(~p"/api/books/#{book.id}")

      assert payload = json_response(conn, 200)
      assert payload["id"] == book.id
      assert payload["title"] == "Detail Book"
      assert payload["is_completed"] == false
      assert payload["cover_url"] =~ "covers/detail.jpg"
      assert [chapter_payload] = payload["chapters"]
      assert chapter_payload["id"] == chapter.id
      assert chapter_payload["position"] == 0
      assert chapter_payload["audio_url"] =~ ".mp3"
      assert payload["progress"]["chapter_id"] == chapter.id
      assert payload["progress"]["offset_ms"] == 321
      assert payload["progress"]["is_completed"] == false
      assert is_binary(payload["progress"]["updated_at"])
    end

    test "returns 400 for malformed book IDs", %{conn: conn} do
      conn = get(authenticated_conn(conn), ~p"/api/books/not-an-id")

      assert json_response(conn, 400) == %{"error" => "Invalid book ID"}
    end

    test "returns 404 for missing books", %{conn: conn} do
      conn = get(authenticated_conn(conn), ~p"/api/books/999999")

      assert json_response(conn, 404) == %{"error" => "Book not found"}
    end
  end

  describe "progress/2" do
    test "returns default progress when the authenticated user has no progress", %{conn: conn} do
      {book, _chapter} = book_with_chapter_fixture("Default Progress Book")

      conn = get(authenticated_conn(conn), ~p"/api/books/#{book.id}/progress")

      assert json_response(conn, 200) == %{
               "chapter_id" => nil,
               "offset_ms" => 0,
               "updated_at" => nil,
               "is_completed" => false
             }
    end

    test "returns saved progress for the authenticated user", %{conn: conn} do
      user = user_fixture()
      other_user = user_fixture()
      token = Accounts.generate_user_session_token(user)
      {book, chapter} = book_with_chapter_fixture("Saved Progress Book")

      assert {:ok, _progress} = Library.save_listen_progress(user.id, book.id, chapter.id, 321)
      assert {:ok, _progress} = Library.mark_book_complete(other_user.id, book.id, chapter.id)

      conn =
        conn
        |> authenticated_conn(token)
        |> get(~p"/api/books/#{book.id}/progress")

      payload = json_response(conn, 200)
      assert payload["chapter_id"] == chapter.id
      assert payload["offset_ms"] == 321
      assert payload["is_completed"] == false
      assert is_binary(payload["updated_at"])
    end
  end

  describe "update_progress/2" do
    test "saves progress and returns 204", %{conn: conn} do
      user = user_fixture()
      token = Accounts.generate_user_session_token(user)
      {book, chapter} = book_with_chapter_fixture("Update Progress Book")

      conn =
        conn
        |> authenticated_conn(token)
        |> put(~p"/api/books/#{book.id}/progress", %{chapter_id: chapter.id, offset_ms: 123})

      assert response(conn, 204) == ""

      assert %ListenProgress{chapter_id: chapter_id, offset_ms: 123, is_completed: false} =
               Library.get_listen_progress(user.id, book.id)

      assert chapter_id == chapter.id
    end

    test "marks a completed book incomplete when newer progress is saved", %{conn: conn} do
      user = user_fixture()
      token = Accounts.generate_user_session_token(user)
      {book, chapter} = book_with_chapter_fixture("Resume Completed Book")

      assert {:ok, _progress} = Library.mark_book_complete(user.id, book.id, chapter.id)

      conn =
        conn
        |> authenticated_conn(token)
        |> put(~p"/api/books/#{book.id}/progress", %{chapter_id: chapter.id, offset_ms: 456})

      assert response(conn, 204) == ""

      assert %ListenProgress{offset_ms: 456, is_completed: false} =
               Library.get_listen_progress(user.id, book.id)
    end

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
    test "marks the first chapter complete when no chapter is supplied", %{conn: conn} do
      user = user_fixture()
      token = Accounts.generate_user_session_token(user)
      {book, first_chapter} = book_with_chapter_fixture("Complete Book")
      _second_chapter = chapter_fixture(book, "Chapter 2", 1, 1_000, 2_000)

      conn =
        conn
        |> authenticated_conn(token)
        |> put(~p"/api/books/#{book.id}/complete", %{})

      assert response(conn, 204) == ""

      assert %ListenProgress{chapter_id: chapter_id, offset_ms: 0, is_completed: true} =
               Library.get_listen_progress(user.id, book.id)

      assert chapter_id == first_chapter.id
    end

    test "returns 422 when a book has no chapters", %{conn: conn} do
      book = book_fixture("Empty Book")

      conn = put(authenticated_conn(conn), ~p"/api/books/#{book.id}/complete", %{})

      assert json_response(conn, 422) == %{"error" => "Book has no chapters"}
    end
  end

  describe "incomplete/2" do
    test "marks existing progress incomplete", %{conn: conn} do
      user = user_fixture()
      token = Accounts.generate_user_session_token(user)
      {book, chapter} = book_with_chapter_fixture("Incomplete Book")

      assert {:ok, _progress} = Library.mark_book_complete(user.id, book.id, chapter.id)

      conn =
        conn
        |> authenticated_conn(token)
        |> put(~p"/api/books/#{book.id}/incomplete", %{})

      assert response(conn, 204) == ""

      assert %ListenProgress{chapter_id: chapter_id, is_completed: false} =
               Library.get_listen_progress(user.id, book.id)

      assert chapter_id == chapter.id
    end

    test "returns 204 when progress does not exist", %{conn: conn} do
      user = user_fixture()
      token = Accounts.generate_user_session_token(user)
      {book, _chapter} = book_with_chapter_fixture("No Progress Incomplete Book")

      conn =
        conn
        |> authenticated_conn(token)
        |> put(~p"/api/books/#{book.id}/incomplete", %{})

      assert response(conn, 204) == ""
      assert Library.get_listen_progress(user.id, book.id) == nil
    end
  end

  defp authenticated_conn(conn) do
    user = user_fixture()
    token = Accounts.generate_user_session_token(user)

    authenticated_conn(conn, token)
  end

  defp authenticated_conn(conn, token) do
    conn
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", "Bearer #{Base.url_encode64(token, padding: false)}")
  end

  defp user_fixture do
    {:ok, user} = Accounts.register_user(%{sub: Ecto.UUID.generate(), name: "Test User"})
    user
  end

  defp book_fixture(title, attrs \\ %{}) do
    {:ok, book} =
      %Book{}
      |> Book.changeset(Map.merge(%{title: title}, Map.new(attrs)))
      |> Repo.insert()

    book
  end

  defp book_with_chapter_fixture(title, attrs \\ %{}) do
    book = book_fixture(title, attrs)
    media_asset = Library.create_media_asset!("books/#{Ecto.UUID.generate()}.mp3")

    chapter = chapter_fixture(book, "Chapter 1", 0, 0, 1_000, media_asset)

    {book, chapter}
  end

  defp chapter_fixture(book, title, position, start_ms, end_ms, media_asset \\ nil) do
    media_asset = media_asset || Library.create_media_asset!("books/#{Ecto.UUID.generate()}.mp3")

    {:ok, chapter} =
      %Chapter{}
      |> Chapter.changeset(%{
        title: title,
        position: position,
        start_ms: start_ms,
        end_ms: end_ms,
        duration_ms: end_ms - start_ms,
        book_id: book.id,
        media_asset_id: media_asset.id
      })
      |> Repo.insert()

    chapter
  end
end
