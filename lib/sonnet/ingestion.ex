defmodule Sonnet.Ingestion do
  @moduledoc """
  Public ingestion orchestration helpers used by upload UIs.
  """

  @staging_prefix "staging"

  def presign_upload(entry, socket) do
    key = Path.join([@staging_prefix, Ecto.UUID.generate()])
    url = Sonnet.Storage.presigned_put_url(key, 3600, [{"Content-Type", entry.client_type}])

    {:ok, %{uploader: "S3", key: key, url: url}, socket}
  end

  def enqueue_single_file(s3_key, original_filename, book_metadata \\ %{}, opts \\ []) do
    delete_source_on_failure = Keyword.get(opts, :delete_source_on_failure, true)

    %{
      "s3_key" => s3_key,
      "original_filename" => original_filename,
      "book_metadata" => book_metadata || %{},
      "delete_source_on_failure" => delete_source_on_failure
    }
    |> Sonnet.Workers.Ingester.new()
    |> Oban.insert()
  end

  @doc """
  Enqueues bulk import jobs for existing S3 keys.

  Source objects are deleted on successful ingestion only and are never deleted on failure.
  """
  def enqueue_bulk_keys(keys) do
    Enum.map(keys, fn key ->
      enqueue_single_file(key, Path.basename(key), %{}, delete_source_on_failure: false)
    end)
  end

  def enqueue_multi_file(files, book_metadata \\ %{}, opts \\ []) do
    delete_source_on_failure = Keyword.get(opts, :delete_source_on_failure, true)

    %{
      "s3_keys" => Enum.map(files, & &1.key),
      "original_filenames" => Enum.map(files, & &1.client_name),
      "book_metadata" => book_metadata || %{},
      "delete_source_on_failure" => delete_source_on_failure
    }
    |> Sonnet.Workers.MultiIngester.new()
    |> Oban.insert()
  end
end
