defmodule Sonnet.Workers.CleanupWorkersTest do
  use Sonnet.DataCase, async: true
  use Oban.Testing, repo: Sonnet.Repo

  alias Sonnet.Library
  alias Sonnet.Library.MediaAsset
  alias Sonnet.Test.S3Stub
  alias Sonnet.Workers.MediaAssetCleanup
  alias Sonnet.Workers.MediaAssetCleanupSingle
  alias Sonnet.Workers.S3ObjectCleanup

  setup do
    %{s3: S3Stub.start!()}
  end

  describe "MediaAssetCleanup" do
    test "schedule_cleanup/1 enqueues flat args without double-nesting" do
      assert {:ok, job} =
               MediaAssetCleanup.schedule_cleanup(batch_size: 25, grace_period_minutes: 30)

      assert job.args == %{"batch_size" => 25, "grace_period_minutes" => 30}
    end

    test "respects grace period and only fans out cleanup for aged unreferenced assets" do
      fresh_orphan = Library.create_media_asset!("books/fresh-orphan.m4b")
      aged_orphan = Library.create_media_asset!("books/aged-orphan.m4b")

      aged_time = DateTime.add(DateTime.utc_now(), -120, :minute) |> DateTime.truncate(:second)

      from(ma in MediaAsset, where: ma.id == ^aged_orphan.id)
      |> Repo.update_all(set: [inserted_at: aged_time])

      {:ok, %{book: _book}} =
        Library.create_book_with_chapters(
          [%{s3_key: "books/active.m4b", title: "Ch 1", duration_ms: 1_000}],
          %{"title" => "Active Book"}
        )

      active_asset = Repo.get_by!(MediaAsset, s3_key: "books/active.m4b")

      from(ma in MediaAsset, where: ma.id == ^active_asset.id)
      |> Repo.update_all(set: [inserted_at: aged_time])

      assert :ok = perform_job(MediaAssetCleanup, %{"batch_size" => 100})

      assert_enqueued(
        worker: MediaAssetCleanupSingle,
        args: %{"media_asset_id" => aged_orphan.id}
      )

      refute_enqueued(
        worker: MediaAssetCleanupSingle,
        args: %{"media_asset_id" => fresh_orphan.id}
      )

      refute_enqueued(
        worker: MediaAssetCleanupSingle,
        args: %{"media_asset_id" => active_asset.id}
      )
    end
  end

  describe "MediaAssetCleanupSingle" do
    test "deletes unreferenced asset from S3 and DB", %{s3: s3} do
      asset = Library.create_media_asset!("books/orphan.m4b")
      S3Stub.put_object(s3, "books/orphan.m4b", "audio")

      assert :ok = perform_job(MediaAssetCleanupSingle, %{"media_asset_id" => asset.id})

      refute S3Stub.has_object?(s3, "books/orphan.m4b")
      assert Repo.get(MediaAsset, asset.id) == nil
    end

    test "skips assets that are currently referenced by a chapter", %{s3: s3} do
      {:ok, %{book: book}} =
        Library.create_book_with_chapters(
          [%{s3_key: "books/live.m4b", title: "Ch 1", duration_ms: 1_000}],
          %{"title" => "Live Book"}
        )

      book = Repo.preload(book, chapters: :media_asset)
      asset = hd(book.chapters).media_asset
      S3Stub.put_object(s3, asset.s3_key, "audio")

      assert :ok = perform_job(MediaAssetCleanupSingle, %{"media_asset_id" => asset.id})

      assert S3Stub.has_object?(s3, asset.s3_key)
      assert Repo.get(MediaAsset, asset.id) != nil
    end

    test "retries on transient S3 delete error without deleting the DB row", %{s3: s3} do
      asset = Library.create_media_asset!("books/s3-down.m4b")
      S3Stub.put_object(s3, "books/s3-down.m4b", "audio")
      S3Stub.fail_next(s3, :delete, "books/s3-down.m4b", 503)

      assert {:error, {:transient, {:http_error, 503, _}}} =
               perform_job(MediaAssetCleanupSingle, %{"media_asset_id" => asset.id})

      assert S3Stub.has_object?(s3, "books/s3-down.m4b")
      assert Repo.get(MediaAsset, asset.id) != nil

      assert :ok = perform_job(MediaAssetCleanupSingle, %{"media_asset_id" => asset.id})
      refute S3Stub.has_object?(s3, "books/s3-down.m4b")
      assert Repo.get(MediaAsset, asset.id) == nil
    end
  end

  describe "S3ObjectCleanup" do
    test "skips deletion when only_if_unreferenced is true and a chapter or cover references the key",
         %{s3: s3} do
      {:ok, _} =
        Library.create_book_with_chapters(
          [%{s3_key: "books/ref.m4b", title: "Ch 1", duration_ms: 1_000}],
          %{"title" => "Ref Book"},
          cover_s3_key: "covers/ref.jpg"
        )

      S3Stub.put_object(s3, "books/ref.m4b", "audio")
      S3Stub.put_object(s3, "covers/ref.jpg", "jpg")

      assert :ok =
               perform_job(S3ObjectCleanup, %{
                 "s3_key" => "books/ref.m4b",
                 "only_if_unreferenced" => true
               })

      assert :ok =
               perform_job(S3ObjectCleanup, %{
                 "s3_key" => "covers/ref.jpg",
                 "only_if_unreferenced" => true
               })

      assert S3Stub.has_object?(s3, "books/ref.m4b")
      assert S3Stub.has_object?(s3, "covers/ref.jpg")
    end

    test "deletes unreferenced keys and retries transient errors", %{s3: s3} do
      S3Stub.put_object(s3, "staging/old", "raw")
      S3Stub.fail_next(s3, :delete, "staging/old", :timeout)

      assert {:error, {:transient, _}} =
               perform_job(S3ObjectCleanup, %{
                 "s3_key" => "staging/old",
                 "only_if_unreferenced" => false
               })

      assert S3Stub.has_object?(s3, "staging/old")

      assert :ok =
               perform_job(S3ObjectCleanup, %{
                 "s3_key" => "staging/old",
                 "only_if_unreferenced" => false
               })

      refute S3Stub.has_object?(s3, "staging/old")
    end
  end
end
