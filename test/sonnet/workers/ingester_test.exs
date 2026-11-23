defmodule Sonnet.Workers.IngesterTest do
  use Sonnet.DataCase, async: true
  use Oban.Testing, repo: Sonnet.Repo

  alias Sonnet.Library
  alias Sonnet.Library.Book
  alias Sonnet.Media
  alias Sonnet.Test.AudioFixtures
  alias Sonnet.Test.S3Stub
  alias Sonnet.Workers.Ingester
  alias Sonnet.Workers.S3ObjectCleanup

  setup do
    %{s3: S3Stub.start!()}
  end

  test "ingests a chaptered m4b with embedded cover and atomically enqueues staging cleanup", %{
    s3: s3
  } do
    source_key = "staging/book-1"

    Media.with_temp_dir(fn dir ->
      path =
        AudioFixtures.generate_m4b!(dir, "book.m4b",
          duration_seconds: 2,
          chapters: [{"Part One", 0, 1000}, {"Part Two", 1000, 2000}],
          title: "Probe Title",
          artist: "Probe Author",
          with_cover: true
        )

      S3Stub.put_file(s3, source_key, path)
    end)

    assert :ok =
             perform_job(Ingester, %{
               "s3_key" => source_key,
               "original_filename" => "Fallback Name.m4b",
               "book_metadata" => %{},
               "delete_source_on_failure" => true
             })

    assert [book] = Repo.all(Book) |> Repo.preload(chapters: :media_asset)
    assert book.title == "Probe Title"
    assert book.author == "Probe Author"
    assert is_binary(book.cover_s3_key)
    assert String.starts_with?(book.cover_s3_key, "covers/")
    assert S3Stub.has_object?(s3, book.cover_s3_key)

    chapters = Enum.sort_by(book.chapters, & &1.position)
    assert [ch1, ch2] = chapters
    assert ch1.title == "Part One"
    assert ch2.title == "Part Two"
    assert String.starts_with?(ch1.media_asset.s3_key, "books/")
    assert S3Stub.has_object?(s3, ch1.media_asset.s3_key)
    assert S3Stub.has_object?(s3, ch2.media_asset.s3_key)

    assert_enqueued(
      worker: S3ObjectCleanup,
      args: %{"s3_key" => source_key, "only_if_unreferenced" => false}
    )

    assert :ok =
             perform_job(S3ObjectCleanup, %{
               "s3_key" => source_key,
               "only_if_unreferenced" => false
             })

    refute S3Stub.has_object?(s3, source_key)
  end

  test "uses original_filename as fallback title when user and probe metadata lack a title", %{
    s3: s3
  } do
    source_key = "staging/no-tags"

    Media.with_temp_dir(fn dir ->
      path = AudioFixtures.generate_m4b!(dir, "plain.m4b", duration_seconds: 1)
      S3Stub.put_file(s3, source_key, path)
    end)

    assert :ok =
             perform_job(Ingester, %{
               "s3_key" => source_key,
               "original_filename" => "The Great Audiobook.m4b",
               "book_metadata" => %{},
               "delete_source_on_failure" => true
             })

    assert [book] = Repo.all(Book)
    assert book.title == "The Great Audiobook"
  end

  test "preserves staging source across transient errors and succeeds on retry", %{s3: s3} do
    source_key = "staging/retry-book"

    Media.with_temp_dir(fn dir ->
      path =
        AudioFixtures.generate_m4b!(dir, "retry.m4b", duration_seconds: 1, title: "Retry Book")

      S3Stub.put_file(s3, source_key, path)
    end)

    S3Stub.fail_next(s3, :head, source_key, :timeout)

    assert {:error, {:ingestion_failed, :download_failed, {:transient, _}}} =
             perform_job(
               Ingester,
               %{
                 "s3_key" => source_key,
                 "original_filename" => "retry.m4b",
                 "book_metadata" => %{},
                 "delete_source_on_failure" => true
               },
               attempt: 1,
               max_attempts: 5
             )

    assert S3Stub.has_object?(s3, source_key)
    assert Repo.all(Book) == []

    assert :ok =
             perform_job(
               Ingester,
               %{
                 "s3_key" => source_key,
                 "original_filename" => "retry.m4b",
                 "book_metadata" => %{},
                 "delete_source_on_failure" => true
               },
               attempt: 2,
               max_attempts: 5
             )

    assert [%Book{title: "Retry Book"}] = Repo.all(Book)
  end

  test "rolls back uploaded cover on transient segment upload error while keeping source for retry",
       %{s3: s3} do
    source_key = "staging/partial-upload"

    Media.with_temp_dir(fn dir ->
      path =
        AudioFixtures.generate_m4b!(dir, "with_cover.m4b",
          duration_seconds: 1,
          title: "Cover Rollback",
          with_cover: true
        )

      S3Stub.put_file(s3, source_key, path)
    end)

    S3Stub.fail_next(s3, :upload, &String.starts_with?(&1, "books/"), 503)

    assert {:error,
            {:ingestion_failed, :segment_upload_failed, {:transient, {:http_error, 503, _}}}} =
             perform_job(
               Ingester,
               %{
                 "s3_key" => source_key,
                 "original_filename" => "with_cover.m4b",
                 "book_metadata" => %{},
                 "delete_source_on_failure" => true
               },
               attempt: 1,
               max_attempts: 5
             )

    assert S3Stub.list_keys(s3) == [source_key]
    assert Repo.all(Book) == []
  end

  test "never deletes shared content-addressed assets belonging to an existing book on rollback",
       %{
         s3: s3
       } do
    first_source = "staging/book-a"
    second_source = "staging/book-b"

    Media.with_temp_dir(fn dir ->
      path =
        AudioFixtures.generate_m4b!(dir, "shared.m4b",
          duration_seconds: 1,
          title: "Shared Book",
          with_cover: true
        )

      S3Stub.put_file(s3, first_source, path)
      S3Stub.put_file(s3, second_source, path)
    end)

    assert :ok =
             perform_job(Ingester, %{
               "s3_key" => first_source,
               "original_filename" => "shared.m4b",
               "book_metadata" => %{},
               "delete_source_on_failure" => true
             })

    [existing_book] = Repo.all(Book) |> Repo.preload(chapters: :media_asset)
    shared_cover = existing_book.cover_s3_key
    shared_segment = hd(existing_book.chapters).media_asset.s3_key

    S3Stub.fail_next(s3, :upload, shared_segment, 503)

    assert {:error,
            {:ingestion_failed, :segment_upload_failed, {:transient, {:http_error, 503, _}}}} =
             perform_job(
               Ingester,
               %{
                 "s3_key" => second_source,
                 "original_filename" => "shared.m4b",
                 "book_metadata" => %{},
                 "delete_source_on_failure" => true
               },
               attempt: 5,
               max_attempts: 5
             )

    assert S3Stub.has_object?(s3, shared_cover)
    assert S3Stub.has_object?(s3, shared_segment)
    assert Library.s3_key_referenced?(shared_cover)
    assert Library.s3_key_referenced?(shared_segment)
    refute S3Stub.has_object?(s3, second_source)
  end

  test "cancels permanent errors and respects delete_source_on_failure policy", %{s3: s3} do
    assert {:cancel, {:ingestion_failed, :download_failed, :not_found}} =
             perform_job(
               Ingester,
               %{
                 "s3_key" => "staging/missing",
                 "original_filename" => "missing.m4b",
                 "book_metadata" => %{},
                 "delete_source_on_failure" => true
               },
               attempt: 1,
               max_attempts: 5
             )

    staging_corrupt = "staging/corrupt"
    S3Stub.put_object(s3, staging_corrupt, "not real audio")

    assert {:cancel, {:ingestion_failed, :probe_failed, {:permanent, {:ffprobe_failed, _}}}} =
             perform_job(
               Ingester,
               %{
                 "s3_key" => staging_corrupt,
                 "original_filename" => "corrupt.m4b",
                 "book_metadata" => %{},
                 "delete_source_on_failure" => true
               },
               attempt: 1,
               max_attempts: 5
             )

    refute S3Stub.has_object?(s3, staging_corrupt)

    bulk_corrupt = "incoming/corrupt.m4b"
    S3Stub.put_object(s3, bulk_corrupt, "not real audio")

    assert {:cancel, {:ingestion_failed, :probe_failed, {:permanent, {:ffprobe_failed, _}}}} =
             perform_job(
               Ingester,
               %{
                 "s3_key" => bulk_corrupt,
                 "original_filename" => "corrupt.m4b",
                 "book_metadata" => %{},
                 "delete_source_on_failure" => false
               },
               attempt: 1,
               max_attempts: 5
             )

    assert S3Stub.has_object?(s3, bulk_corrupt)
  end

  test "enqueues async S3ObjectCleanup on terminal failure if synchronous source deletion fails",
       %{
         s3: s3
       } do
    source_key = "staging/final-attempt-cleanup"
    S3Stub.put_object(s3, source_key, "not real audio")
    S3Stub.fail_next(s3, :delete, source_key, 503)

    assert {:cancel, {:ingestion_failed, :probe_failed, {:permanent, _}}} =
             perform_job(
               Ingester,
               %{
                 "s3_key" => source_key,
                 "original_filename" => "corrupt.m4b",
                 "book_metadata" => %{},
                 "delete_source_on_failure" => true
               },
               attempt: 1,
               max_attempts: 5
             )

    assert S3Stub.has_object?(s3, source_key)

    assert_enqueued(
      worker: S3ObjectCleanup,
      args: %{"s3_key" => source_key, "only_if_unreferenced" => false}
    )
  end
end
