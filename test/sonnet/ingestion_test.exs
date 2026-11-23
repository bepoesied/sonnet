defmodule Sonnet.IngestionTest do
  use Sonnet.DataCase, async: true
  use Oban.Testing, repo: Sonnet.Repo

  alias Sonnet.Ingestion
  alias Sonnet.Workers.Ingester
  alias Sonnet.Workers.MultiIngester

  describe "Oban queue configuration" do
    test "caps the :ingestion queue concurrency at 3 and validates cleanly" do
      oban_config = Application.fetch_env!(:sonnet, Oban)

      assert oban_config[:queues][:ingestion] == 3
      assert :ok == oban_config |> Keyword.delete(:testing) |> Oban.Config.validate()
    end
  end

  describe "JobOutcome.classify_postgrex_error/1" do
    alias Sonnet.Ingestion.JobOutcome

    test "classifies data/constraint SQLSTATEs as permanent and connection/deadlock errors as transient" do
      constraint_err = %Postgrex.Error{postgres: %{pg_code: "23514"}}
      deadlock_err = %Postgrex.Error{postgres: %{pg_code: "40P01"}}
      conn_err = %Postgrex.Error{postgres: %{pg_code: "08006"}}

      assert {:permanent, ^constraint_err} = JobOutcome.classify_postgrex_error(constraint_err)
      assert {:transient, ^deadlock_err} = JobOutcome.classify_postgrex_error(deadlock_err)
      assert {:transient, ^conn_err} = JobOutcome.classify_postgrex_error(conn_err)
    end
  end

  describe "presign_upload/2" do
    test "generates keys under the staging/ prefix" do
      {:ok, meta, :socket} =
        Ingestion.presign_upload(%{client_type: "audio/mp4"}, :socket)

      assert meta.uploader == "S3"
      assert String.starts_with?(meta.key, "staging/")
      assert is_binary(meta.url)
    end
  end

  describe "enqueue_single_file/4" do
    test "enqueues onto the :ingestion queue with max_attempts 5 and delete_source_on_failure true" do
      assert {:ok, job} =
               Ingestion.enqueue_single_file("staging/abc", "My Book.m4b", %{"title" => "My Book"})

      assert job.queue == "ingestion"
      assert job.max_attempts == 5

      assert_enqueued(
        worker: Ingester,
        queue: :ingestion,
        args: %{
          "s3_key" => "staging/abc",
          "original_filename" => "My Book.m4b",
          "book_metadata" => %{"title" => "My Book"},
          "delete_source_on_failure" => true
        }
      )
    end

    test "deduplicates active jobs for the same s3_key" do
      assert {:ok, first} = Ingestion.enqueue_single_file("staging/dup", "Book.m4b")
      assert {:ok, second} = Ingestion.enqueue_single_file("staging/dup", "Book.m4b")
      assert first.id == second.id
    end
  end

  describe "enqueue_bulk_keys/1" do
    test "sets delete_source_on_failure to false so bulk-imported objects are only deleted on success" do
      results = Ingestion.enqueue_bulk_keys(["incoming/a.m4b", "incoming/b.m4b"])
      assert Enum.all?(results, &match?({:ok, _}, &1))

      assert_enqueued(
        worker: Ingester,
        queue: :ingestion,
        args: %{
          "s3_key" => "incoming/a.m4b",
          "original_filename" => "a.m4b",
          "book_metadata" => %{},
          "delete_source_on_failure" => false
        }
      )

      assert_enqueued(
        worker: Ingester,
        queue: :ingestion,
        args: %{
          "s3_key" => "incoming/b.m4b",
          "original_filename" => "b.m4b",
          "book_metadata" => %{},
          "delete_source_on_failure" => false
        }
      )
    end
  end

  describe "enqueue_multi_file/3" do
    test "enqueues onto the :ingestion queue with max_attempts 5" do
      files = [
        %{key: "staging/1", client_name: "Chapter 1.mp3"},
        %{key: "staging/2", client_name: "Chapter 2.mp3"}
      ]

      assert {:ok, job} = Ingestion.enqueue_multi_file(files, %{"title" => "Series"})
      assert job.queue == "ingestion"
      assert job.max_attempts == 5

      assert_enqueued(
        worker: MultiIngester,
        queue: :ingestion,
        args: %{
          "s3_keys" => ["staging/1", "staging/2"],
          "original_filenames" => ["Chapter 1.mp3", "Chapter 2.mp3"],
          "book_metadata" => %{"title" => "Series"},
          "delete_source_on_failure" => true
        }
      )
    end
  end
end
