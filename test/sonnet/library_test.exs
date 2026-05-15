defmodule Sonnet.LibraryTest do
  use Sonnet.DataCase, async: true

  alias Sonnet.Library
  alias Sonnet.Library.Book
  alias Sonnet.Library.Chapter

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
end
