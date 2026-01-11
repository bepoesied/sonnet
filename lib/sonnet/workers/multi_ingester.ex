defmodule Sonnet.Workers.MultiIngester do
  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    s3_keys = args["s3_keys"]
    original_filenames = args["original_filenames"]
    book_metadata = args["book_metadata"] || %{}

    try do
      case ingest_multi_files(s3_keys, original_filenames, book_metadata) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.error("Fatal error ingesting multi-file book: #{inspect(reason)}")
          cleanup_fatal(s3_keys)
          {:error, reason}
      end
    rescue
      e ->
        Logger.error("Fatal exception ingesting multi-file book: #{inspect(e)}")
        cleanup_fatal(s3_keys)
        {:error, e}
    end
  end

  defp ingest_multi_files(s3_keys, original_filenames, book_metadata) do
    files_with_durations =
      Enum.zip(s3_keys, original_filenames)
      |> Enum.map(fn {s3_key, original_filename} ->
        duration = probe_audio_duration(s3_key)
        %{s3_key: s3_key, original_filename: original_filename, duration_ms: duration}
      end)

    sorted_files = Enum.sort_by(files_with_durations, & &1.original_filename)
    media_assets = Enum.map(sorted_files, &Sonnet.Library.create_media_asset!(&1.s3_key))

    case Sonnet.Library.ingest_multi_file!(
           Enum.map(sorted_files, & &1.s3_key),
           Enum.map(sorted_files, & &1.original_filename),
           media_assets,
           Enum.map(sorted_files, & &1.duration_ms),
           book_metadata
         ) do
      {:ok, _} ->
        Sonnet.Library.broadcast_books_updated()
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp probe_audio_duration(s3_key) do
    path = Briefly.create!(type: :path)

    case Sonnet.Storage.download_file(s3_key, path) do
      {:ok, _} ->
        case System.cmd("ffprobe", [
               "-v",
               "quiet",
               "-print_format",
               "json",
               "-show_format",
               path
             ]) do
          {output, 0} ->
            case Jason.decode(output) do
              {:ok, %{"format" => %{"duration" => duration}}} ->
                floor(String.to_float(duration) * 1000)

              _ ->
                0
            end

          _ ->
            0
        end

      _ ->
        0
    end
  end

  defp cleanup_fatal(s3_keys) do
    Enum.each(s3_keys, fn s3_key ->
      Sonnet.Storage.delete_object(s3_key)
      Sonnet.Library.delete_media_asset_by_s3_key(s3_key)
    end)

    :ok
  rescue
    e ->
      Logger.warning("Cleanup failed for multi-file ingestion: #{inspect(e)}")
      :ok
  end
end
