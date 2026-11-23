defmodule Sonnet.Workers.MultiIngesterTest do
  use Sonnet.DataCase, async: true
  use Oban.Testing, repo: Sonnet.Repo

  alias Sonnet.Library.Book
  alias Sonnet.Media
  alias Sonnet.Test.AudioFixtures
  alias Sonnet.Test.S3Stub
  alias Sonnet.Workers.MultiIngester
  alias Sonnet.Workers.S3ObjectCleanup

  setup do
    %{s3: S3Stub.start!()}
  end

  test "naturally sorts tracks, extracts fallback ID3 metadata, promotes to books/, and enqueues staging cleanup",
       %{s3: s3} do
    keys = ["staging/ch10", "staging/ch2", "staging/ch1"]
    names = ["Chapter 10.mp3", "Chapter 2.mp3", "Chapter 1.mp3"]

    Media.with_temp_dir(fn dir ->
      p1 =
        AudioFixtures.generate_mp3!(dir, "ch1.mp3",
          duration_seconds: 1,
          frequency: 440,
          title: "ID3 Book Title",
          artist: "ID3 Author"
        )

      p2 = AudioFixtures.generate_mp3!(dir, "ch2.mp3", duration_seconds: 1, frequency: 550)
      p10 = AudioFixtures.generate_mp3!(dir, "ch10.mp3", duration_seconds: 1, frequency: 660)

      S3Stub.put_file(s3, "staging/ch1", p1)
      S3Stub.put_file(s3, "staging/ch2", p2)
      S3Stub.put_file(s3, "staging/ch10", p10)
    end)

    assert :ok =
             perform_job(MultiIngester, %{
               "s3_keys" => keys,
               "original_filenames" => names,
               "book_metadata" => %{},
               "delete_source_on_failure" => true
             })

    assert [book] = Repo.all(Book) |> Repo.preload(chapters: :media_asset)
    assert book.title == "ID3 Book Title"
    assert book.author == "ID3 Author"

    chapters = Enum.sort_by(book.chapters, & &1.position)
    assert Enum.map(chapters, & &1.title) == ["Chapter 1", "Chapter 2", "Chapter 10"]

    for chapter <- chapters do
      assert String.starts_with?(chapter.media_asset.s3_key, "books/")
      assert String.ends_with?(chapter.media_asset.s3_key, ".mp3")
      assert S3Stub.has_object?(s3, chapter.media_asset.s3_key)
      assert chapter.duration_ms > 0
    end

    for staging_key <- keys do
      assert_enqueued(
        worker: S3ObjectCleanup,
        args: %{"s3_key" => staging_key, "only_if_unreferenced" => false}
      )
    end
  end

  test "rolls back uploaded tracks and preserves staging files on transient mid-book failure", %{
    s3: s3
  } do
    keys = ["staging/t1", "staging/t2"]
    names = ["01 First.mp3", "02 Second.mp3"]

    Media.with_temp_dir(fn dir ->
      p1 = AudioFixtures.generate_mp3!(dir, "t1.mp3", duration_seconds: 1, frequency: 440)
      p2 = AudioFixtures.generate_mp3!(dir, "t2.mp3", duration_seconds: 1, frequency: 550)
      S3Stub.put_file(s3, "staging/t1", p1)
      S3Stub.put_file(s3, "staging/t2", p2)
    end)

    S3Stub.fail_next(s3, :head, "staging/t2", :econnrefused)

    assert {:error, {:ingestion_failed, :download_failed, {:transient, _}}} =
             perform_job(
               MultiIngester,
               %{
                 "s3_keys" => keys,
                 "original_filenames" => names,
                 "book_metadata" => %{"title" => "Retry Multi"},
                 "delete_source_on_failure" => true
               },
               attempt: 1,
               max_attempts: 5
             )

    assert S3Stub.list_keys(s3) == ["staging/t1", "staging/t2"]
    assert Repo.all(Book) == []

    assert :ok =
             perform_job(
               MultiIngester,
               %{
                 "s3_keys" => keys,
                 "original_filenames" => names,
                 "book_metadata" => %{"title" => "Retry Multi"},
                 "delete_source_on_failure" => true
               },
               attempt: 2,
               max_attempts: 5
             )

    assert [%Book{title: "Retry Multi"}] = Repo.all(Book)
  end

  test "cancels permanent failures and deletes staging files when delete_source_on_failure is true",
       %{s3: s3} do
    keys = ["staging/good", "staging/bad"]
    names = ["01 Good.mp3", "02 Bad.mp3"]

    Media.with_temp_dir(fn dir ->
      p1 = AudioFixtures.generate_mp3!(dir, "good.mp3", duration_seconds: 1)
      S3Stub.put_file(s3, "staging/good", p1)
    end)

    S3Stub.put_object(s3, "staging/bad", "corrupt bytes")

    assert {:cancel, {:ingestion_failed, :probe_failed, {:permanent, _}}} =
             perform_job(
               MultiIngester,
               %{
                 "s3_keys" => keys,
                 "original_filenames" => names,
                 "book_metadata" => %{"title" => "Broken"},
                 "delete_source_on_failure" => true
               },
               attempt: 1,
               max_attempts: 5
             )

    assert S3Stub.list_keys(s3) == []
    assert Repo.all(Book) == []
  end

  test "cancels immediately on invalid args" do
    assert {:cancel, {:ingestion_failed, :invalid_args, :invalid_file_list}} =
             perform_job(MultiIngester, %{"s3_keys" => [], "original_filenames" => []})
  end
end
