defmodule Sonnet.Workers.MultiIngester do
  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    s3_keys = args["s3_keys"]
    original_filenames = args["original_filenames"]
    book_metadata = args["book_metadata"] || %{}

    case ingest_multi_files(s3_keys, original_filenames, book_metadata) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Fatal error ingesting multi-file book: #{inspect(reason)}")
        cleanup_fatal(s3_keys)
        {:error, reason}
    end
  end

  defp ingest_multi_files(s3_keys, original_filenames, book_metadata) do
    with {:ok, files_with_durations} <-
           probe_and_download_files(s3_keys, original_filenames),
         {:ok, sorted_files} = sort_files(files_with_durations),
         {:ok, media_assets} = create_media_assets(sorted_files),
         {:ok, _} <-
           create_book_and_chapters(
             sorted_files,
             media_assets,
             book_metadata
           ) do
      Sonnet.Library.broadcast_books_updated()
      :ok
    end
  end

  defp probe_and_download_files(s3_keys, original_filenames) do
    results =
      Enum.zip(s3_keys, original_filenames)
      |> Enum.map(fn {s3_key, original_filename} ->
        case probe_audio_duration(s3_key) do
          {:ok, duration, path} ->
            {:ok,
             %{
               s3_key: s3_key,
               original_filename: original_filename,
               duration_ms: duration,
               path: path
             }}

          {:error, reason} ->
            {:error, reason}
        end
      end)

    errors = Enum.filter(results, fn {status, _} -> status == :error end)

    if errors == [] do
      files = Enum.map(results, fn {:ok, file} -> file end)
      {:ok, files}
    else
      {:error, {:probe_failed, errors}}
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
                {:ok, floor(String.to_float(duration) * 1000), path}

              {:error, reason} ->
                {:error, {:json_decode_failed, reason}}

              _ ->
                {:error, :invalid_probe_output}
            end

          {_, exit_code} ->
            {:error, {:ffprobe_failed, exit_code}}
        end

      {:error, reason} ->
        {:error, {:download_failed, reason}}
    end
  end

  defp sort_files(files_with_durations) do
    {:ok, Enum.sort_by(files_with_durations, & &1.original_filename)}
  end

  defp create_media_assets(sorted_files) do
    try do
      media_assets =
        Enum.map(sorted_files, fn %{s3_key: s3_key} ->
          Sonnet.Library.create_media_asset!(s3_key)
        end)

      {:ok, media_assets}
    rescue
      e ->
        {:error, {:media_asset_creation_failed, e}}
    end
  end

  defp create_book_and_chapters(sorted_files, media_assets, book_metadata) do
    case Sonnet.Library.ingest_multi_file!(
           Enum.map(sorted_files, & &1.s3_key),
           Enum.map(sorted_files, & &1.original_filename),
           media_assets,
           Enum.map(sorted_files, & &1.duration_ms),
           book_metadata
         ) do
      {:ok, _} ->
        {:ok, :ok}

      {:error, reason} ->
        {:error, {:book_creation_failed, reason}}
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
