defmodule Sonnet.LibraryTest do
  use Sonnet.DataCase, async: true

  alias Sonnet.Library
  alias Sonnet.Library.Book
  alias Sonnet.Library.Chapter
  alias Sonnet.Accounts

  describe "ingest_segmented!/3" do
    test "creates a book, media assets, and chapters" do
      segments_data = [
        %{s3_key: "books/part-1.mp3", title: "Intro", duration_ms: 1_000},
        %{s3_key: "books/part-2.mp3", title: nil, duration_ms: 2_000}
      ]

      assert {:ok, %{book: book}} =
               Library.ingest_segmented!(
                 segments_data,
                 %{"title" => "Segmented Book"},
                 "covers/cover.jpg"
               )

      assert %Book{title: "Segmented Book", cover_s3_key: "covers/cover.jpg"} = book

      chapters =
        Repo.all(
          from c in Chapter,
            where: c.book_id == ^book.id,
            order_by: c.position,
            preload: [:media_asset]
        )

      assert [first, second] = chapters
      assert first.title == "Intro"
      assert first.start_ms == 0
      assert first.end_ms == 1_000
      assert first.duration_ms == 1_000
      assert first.media_asset.s3_key == "books/part-1.mp3"

      assert second.title == "Chapter 2"
      assert second.start_ms == 1_000
      assert second.end_ms == 3_000
      assert second.duration_ms == 2_000
      assert second.media_asset.s3_key == "books/part-2.mp3"
    end

    test "returns a tagged transaction failure when the book is invalid" do
      segments_data = [
        %{s3_key: "books/part-1.mp3", title: "Broken", duration_ms: 1_000}
      ]

      assert {:error, {:transaction_failed, :book, %Ecto.Changeset{} = changeset, changes}} =
               Library.ingest_segmented!(segments_data, %{"title" => ""})

      assert %{} = changes
      assert "can't be blank" in errors_on(changeset).title
    end
  end

  describe "ingest_multi_file!/5" do
    test "creates chapters from the supplied files" do
      media_assets = [
        Library.create_media_asset!("uploads/part-1.mp3"),
        Library.create_media_asset!("uploads/part-2.mp3")
      ]

      assert {:ok, %{book: book}} =
               Library.ingest_multi_file!(
                 ["uploads/part-1.mp3", "uploads/part-2.mp3"],
                 ["01 Intro.mp3", "02 Outro.mp3"],
                 media_assets,
                 [1_500, 2_500],
                 %{"title" => "Multi Book"}
               )

      assert %Book{title: "Multi Book"} = book

      chapters =
        Repo.all(
          from c in Chapter,
            where: c.book_id == ^book.id,
            order_by: c.position,
            preload: [:media_asset]
        )

      assert [first, second] = chapters
      assert first.title == "01 Intro"
      assert first.start_ms == 0
      assert first.end_ms == 1_500
      assert first.media_asset_id == Enum.at(media_assets, 0).id

      assert second.title == "02 Outro"
      assert second.start_ms == 1_500
      assert second.end_ms == 4_000
      assert second.media_asset_id == Enum.at(media_assets, 1).id
    end

    test "returns a tagged transaction failure when the book is invalid" do
      media_assets = [
        Library.create_media_asset!("uploads/good.mp3"),
        Library.create_media_asset!("uploads/bad.mp3")
      ]

      assert {:error, {:transaction_failed, :book, %Ecto.Changeset{} = changeset, changes}} =
               Library.ingest_multi_file!(
                 ["uploads/good.mp3", "uploads/bad.mp3"],
                 ["01 Good.mp3", "02 Bad.mp3"],
                 media_assets,
                 [1_000, 2_000],
                 %{"title" => ""}
               )

      assert %{} = changes
      assert "can't be blank" in errors_on(changeset).title
    end
  end

  describe "save_listen_progress/5" do
    test "creates and updates one progress row per user and book" do
      user = user_fixture()
      {book, first_chapter} = book_with_chapter_fixture("Single Progress Book")
      second_chapter = chapter_fixture(book, "Chapter 2", 1, 1_000, 2_000)

      assert {:ok, progress} =
               Library.save_listen_progress(user.id, book.id, first_chapter.id, 250)

      assert progress.chapter_id == first_chapter.id
      assert progress.offset_ms == 250
      assert progress.is_completed == false

      assert {:ok, updated_progress} =
               Library.save_listen_progress(user.id, book.id, second_chapter.id, 750)

      assert updated_progress.id == progress.id
      assert updated_progress.chapter_id == second_chapter.id
      assert updated_progress.offset_ms == 750
      assert Repo.aggregate(Library.ListenProgress, :count) == 1
    end

    test "saving progress after completion marks the book incomplete" do
      user = user_fixture()
      {book, chapter} = book_with_chapter_fixture("Completed Progress Book")

      assert {:ok, completed_progress} =
               Library.mark_book_complete(user.id, book.id, chapter.id)

      assert completed_progress.is_completed == true

      assert {:ok, updated_progress} =
               Library.save_listen_progress(user.id, book.id, chapter.id, 500)

      assert updated_progress.id == completed_progress.id
      assert updated_progress.offset_ms == 500
      assert updated_progress.is_completed == false
      assert Library.get_listen_progress(user.id, book.id).is_completed == false
    end

    test "rejects chapters that do not belong to the book" do
      user = user_fixture()
      {_book, chapter} = book_with_chapter_fixture("Right Book")
      {other_book, _other_chapter} = book_with_chapter_fixture("Wrong Book")

      assert {:error, :chapter_not_found} =
               Library.save_listen_progress(user.id, other_book.id, chapter.id, 0)
    end

    test "rejects negative offsets" do
      user = user_fixture()
      {book, chapter} = book_with_chapter_fixture("Offset Book")

      assert {:error, changeset} =
               Library.save_listen_progress(user.id, book.id, chapter.id, -1)

      assert "must be greater than or equal to 0" in errors_on(changeset).offset_ms
    end
  end

  describe "completion state" do
    test "mark_book_incomplete/2 is a no-op when progress does not exist" do
      user = user_fixture()
      {book, _chapter} = book_with_chapter_fixture("No Progress Book")

      assert Library.mark_book_incomplete(user.id, book.id) == {:ok, nil}
      assert Library.get_listen_progress(user.id, book.id) == nil
    end

    test "list_books/1 returns completion state for only the requested user" do
      completed_user = user_fixture()
      other_user = user_fixture()
      {book, chapter} = book_with_chapter_fixture("User Scoped Completion Book")

      assert {:ok, _progress} = Library.mark_book_complete(completed_user.id, book.id, chapter.id)

      assert [%Book{id: book_id, is_completed: true}] = Library.list_books(completed_user.id)
      assert book_id == book.id

      assert [%Book{id: book_id, is_completed: false}] = Library.list_books(other_user.id)
      assert book_id == book.id
    end
  end

  defp user_fixture do
    {:ok, user} = Accounts.register_user(%{sub: Ecto.UUID.generate(), name: "Test User"})
    user
  end

  defp book_with_chapter_fixture(title) do
    {:ok, book} =
      %Book{}
      |> Book.changeset(%{title: title})
      |> Repo.insert()

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
