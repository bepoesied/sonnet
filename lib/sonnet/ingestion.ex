defmodule Sonnet.Ingestion do
  @moduledoc """
  Public ingestion orchestration helpers used by upload UIs.
  """

  def presign_upload(entry, socket) do
    key = Ecto.UUID.generate()
    url = Sonnet.Storage.presigned_put_url(key, 3600, [{"Content-Type", entry.client_type}])

    {:ok, %{uploader: "S3", key: key, url: url}, socket}
  end

  def enqueue_single_file(s3_key, original_filename, book_metadata \\ %{}) do
    %{
      s3_key: s3_key,
      original_filename: original_filename,
      book_metadata: book_metadata
    }
    |> Sonnet.Workers.Ingester.new()
    |> Oban.insert()
  end

  def enqueue_bulk_keys(keys) do
    Enum.map(keys, fn key ->
      enqueue_single_file(key, Path.basename(key))
    end)
  end

  def enqueue_multi_file(files, book_metadata \\ %{}) do
    Sonnet.Workers.MultiIngester.new(%{
      s3_keys: Enum.map(files, & &1.key),
      original_filenames: Enum.map(files, & &1.client_name),
      book_metadata: book_metadata
    })
    |> Oban.insert()
  end
end
