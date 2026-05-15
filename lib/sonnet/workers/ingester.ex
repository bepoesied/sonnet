defmodule Sonnet.Workers.Ingester do
  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    s3_key = args["s3_key"]
    original_filename = args["original_filename"]
    book_metadata = args["book_metadata"] || %{}

    case ingest_single_file(s3_key, original_filename, book_metadata) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Fatal error ingesting #{s3_key}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp ingest_single_file(s3_key, _original_filename, book_metadata) do
    with {:ok, path} <- Sonnet.Media.download_to_temp(s3_key),
         {:ok, probe} <- Sonnet.Media.probe_file(path) do
      cover_s3_key = Sonnet.Media.extract_and_upload_embedded_cover(path, probe)

      case Sonnet.Media.segment_file(path, probe) do
        {:ok, segments} ->
          persist_single_file_ingestion(
            s3_key,
            segments,
            Sonnet.Media.merge_metadata(book_metadata, probe),
            cover_s3_key
          )

        {:error, reason} ->
          cleanup_single_file_failure(s3_key, [], cover_s3_key)
          ingestion_error(:segmentation_failed, reason)
      end
    else
      {:error, reason} ->
        ingestion_error(:download_or_probe_failed, reason)
    end
  end

  defp delete_from_s3(s3_key) do
    case Sonnet.Storage.delete_object(s3_key) do
      :ok -> {:ok, :ok}
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_book_from_segments(segments_data, book_metadata, cover_s3_key) do
    Sonnet.Library.ingest_segmented!(segments_data, book_metadata, cover_s3_key)
  end

  defp persist_single_file_ingestion(original_s3_key, segments, book_metadata, cover_s3_key) do
    case Sonnet.Media.upload_segments(segments) do
      {:ok, segments_data} ->
        case create_book_from_segments(segments_data, book_metadata, cover_s3_key) do
          {:ok, _} ->
            case delete_from_s3(original_s3_key) do
              {:ok, _} ->
                Sonnet.Library.broadcast_books_updated()
                :ok

              {:error, reason} ->
                ingestion_error(:source_cleanup_failed, reason)
            end

          {:error, reason} ->
            cleanup_single_file_failure(original_s3_key, segments_data, cover_s3_key)
            ingestion_error(:book_creation_failed, reason)
        end

      {:error, reason} ->
        cleanup_single_file_failure(original_s3_key, [], cover_s3_key)
        ingestion_error(:segment_upload_failed, reason)
    end
  end

  defp cleanup_single_file_failure(original_s3_key, segments_data, cover_s3_key) do
    cleanup_object(original_s3_key)

    Enum.each(segments_data, fn %{s3_key: s3_key} ->
      cleanup_object(s3_key)
      Sonnet.Library.delete_media_asset_by_s3_key(s3_key)
    end)

    if cover_s3_key do
      cleanup_object(cover_s3_key)
    end

    :ok
  rescue
    e ->
      Logger.warning("Cleanup failed for #{original_s3_key}: #{inspect(e)}")
      :ok
  end

  defp cleanup_object(s3_key) do
    case Sonnet.Storage.delete_object(s3_key) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Cleanup delete failed for #{s3_key}: #{inspect(reason)}")
    end
  end

  defp ingestion_error(step, reason), do: {:error, {:ingestion_failed, step, reason}}
end
