defmodule SonnetWeb.BookSerializerTest do
  use ExUnit.Case, async: true

  alias Sonnet.Library.Book
  alias Sonnet.Library.Chapter
  alias Sonnet.Library.ListenProgress
  alias Sonnet.Library.MediaAsset
  alias SonnetWeb.BookSerializer

  @updated_at ~U[2026-01-02 03:04:05Z]

  test "api_summary/2 returns the list payload without chapters" do
    assert BookSerializer.api_summary(book(), url_fun: &test_url/1) == %{
             id: 1,
             title: "Book Title",
             author: "Author Name",
             narrator: "Narrator Name",
             description: "Book description",
             cover_url: "/media/covers/book.jpg",
             is_completed: true
           }
  end

  test "api_detail/3 returns playback chapter data and API progress" do
    assert BookSerializer.api_detail(book(), progress(), url_fun: &test_url/1) == %{
             id: 1,
             title: "Book Title",
             author: "Author Name",
             narrator: "Narrator Name",
             description: "Book description",
             cover_url: "/media/covers/book.jpg",
             is_completed: true,
             chapters: [
               %{
                 id: 2,
                 title: "Chapter 1",
                 position: 0,
                 start_ms: 0,
                 end_ms: 1_000,
                 duration_ms: 1_000,
                 media_asset_id: 3,
                 audio_url: "/media/books/chapter-1.mp3"
               }
             ],
             progress: %{
               chapter_id: 2,
               offset_ms: 500,
               updated_at: @updated_at,
               is_completed: false
             }
           }
  end

  test "player_detail/3 returns audio URLs and player progress" do
    assert BookSerializer.player_detail(book(), progress(), url_fun: &test_url/1) == %{
             id: 1,
             title: "Book Title",
             author: "Author Name",
             narrator: "Narrator Name",
             description: "Book description",
             cover_url: "/media/covers/book.jpg",
             is_completed: true,
             chapters: [
               %{
                 id: 2,
                 title: "Chapter 1",
                 position: 0,
                 start_ms: 0,
                 end_ms: 1_000,
                 duration_ms: 1_000,
                 media_asset_id: 3,
                 audio_url: "/media/books/chapter-1.mp3"
               }
             ],
             progress: %{
               chapter_id: 2,
               offset_ms: 500,
               updated_at: @updated_at
             }
           }
  end

  test "progress/1 returns the API default when progress is missing" do
    assert BookSerializer.progress(nil) == %{
             chapter_id: nil,
             offset_ms: 0,
             updated_at: nil,
             is_completed: false
           }
  end

  test "progress/1 returns API progress including completion state" do
    assert BookSerializer.progress(progress()) == %{
             chapter_id: 2,
             offset_ms: 500,
             updated_at: @updated_at,
             is_completed: false
           }
  end

  defp book do
    %Book{
      id: 1,
      title: "Book Title",
      author: "Author Name",
      narrator: "Narrator Name",
      description: "Book description",
      cover_s3_key: "covers/book.jpg",
      is_completed: true,
      chapters: [
        %Chapter{
          id: 2,
          title: "Chapter 1",
          position: 0,
          start_ms: 0,
          end_ms: 1_000,
          duration_ms: 1_000,
          media_asset_id: 3,
          media_asset: %MediaAsset{id: 3, s3_key: "books/chapter-1.mp3"}
        }
      ]
    }
  end

  defp progress do
    %ListenProgress{
      chapter_id: 2,
      offset_ms: 500,
      updated_at: @updated_at,
      is_completed: false
    }
  end

  defp test_url(s3_key), do: "/media/#{s3_key}"
end
