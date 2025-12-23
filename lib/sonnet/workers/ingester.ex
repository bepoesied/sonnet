defmodule Sonnet.Workers.Ingester do
  use Oban.Worker, queue: :default, max_attempts: 10

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    s3_key = args["s3_key"]
    original_filename = args["original_filename"]

    case do_ingest(s3_key, original_filename) do
      :ok ->
        :ok

      {:error, :not_found} ->
        # S3 consistency issue, retry after some time
        {:error, :not_found}

      {:error, {:transient, reason}} ->
        {:error, reason}

      {:error, reason} ->
        Logger.error("Fatal error ingesting #{s3_key}: #{inspect(reason)}")
        cleanup_fatal(s3_key)
        {:cancel, reason}
    end
  end

  defp do_ingest(s3_key, original_filename) do
    with {:ok, path} <- download_from_s3(s3_key),
         {:ok, probe} <- probe_file(path) do
      cover_s3_key = extract_and_upload_cover(path, probe)
      media_asset = Sonnet.Library.create_media_asset!(s3_key)

      case Sonnet.Library.ingest_probe!(probe, media_asset.id, original_filename, cover_s3_key) do
        {:ok, _} ->
          Sonnet.Library.broadcast_books_updated()
          :ok

        {:error, _name, reason, _changes} ->
          {:error, reason}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp download_from_s3(s3_key) do
    key = full_key(s3_key)
    path = Briefly.create!(type: :path)

    case ExAws.S3.download_file(bucket(), key, path) |> ExAws.request() do
      {:ok, _} ->
        {:ok, path}

      {:error, {:http_error, 404, _}} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, {:transient, reason}}
    end
  end

  defp probe_file(path) do
    case System.cmd("ffprobe", [
           "-v",
           "quiet",
           "-print_format",
           "json",
           "-show_format",
           "-show_streams",
           "-show_chapters",
           path
         ]) do
      {output, 0} ->
        case Jason.decode(output) do
          {:ok, decoded} -> {:ok, decoded}
          {:error, reason} -> {:error, "Invalid JSON from ffprobe: #{inspect(reason)}"}
        end

      {_, _} ->
        {:error, "failed to probe file"}
    end
  end

  defp extract_and_upload_cover(path, probe) do
    if has_video_stream?(probe) do
      case extract_cover(path) do
        {:ok, cover_path} ->
          hash = calculate_hash(cover_path)
          upload_cover(cover_path, hash)

        :error ->
          nil
      end
    else
      nil
    end
  end

  defp has_video_stream?(%{"streams" => streams}) do
    Enum.any?(streams, fn stream -> stream["codec_type"] == "video" end)
  end

  defp calculate_hash(path) do
    File.stream!(path)
    |> Enum.reduce(:crypto.hash_init(:sha256), fn chunk, acc ->
      :crypto.hash_update(acc, chunk)
    end)
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp extract_cover(path) do
    output_path = Briefly.create!(type: :path, extname: ".jpg")

    case System.cmd("ffmpeg", ["-i", path, "-frames:v", "1", "-f", "image2", output_path, "-y"]) do
      {_, 0} ->
        if File.exists?(output_path) and File.stat!(output_path).size > 0 do
          {:ok, output_path}
        else
          :error
        end

      {_, _} ->
        :error
    end
  end

  defp upload_cover(path, hash) do
    key = "#{prefix()}/covers/#{hash}.jpg"

    path
    |> ExAws.S3.Upload.stream_file()
    |> ExAws.S3.upload(bucket(), key)
    |> ExAws.request!()

    key
  end

  defp cleanup_fatal(s3_key) do
    # Remove from S3
    ExAws.S3.delete_object(bucket(), full_key(s3_key)) |> ExAws.request()
    # Remove from DB if exists
    Sonnet.Library.delete_media_asset_by_s3_key(s3_key)
    :ok
  rescue
    e ->
      Logger.warning("Cleanup failed for #{s3_key}: #{inspect(e)}")
      :ok
  end

  defp bucket do
    Application.get_env(:sonnet, :ingest_bucket)
  end

  defp prefix do
    Application.get_env(:sonnet, :ingest_prefix)
  end

  defp full_key(s3_key) do
    Path.join(prefix(), s3_key)
  end
end
