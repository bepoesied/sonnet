defmodule Sonnet.Workers.Ingester do
  use Oban.Worker, queue: :default, max_attempts: 10

  require Logger

  @segment_duration_seconds 900

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
        cleanup_fatal(s3_key)
        {:error, reason}
    end
  end

  defp ingest_single_file(s3_key, original_filename, book_metadata) do
    with {:ok, path} <- download_from_s3(s3_key),
         {:ok, probe} <- probe_file(path),
         cover_s3_key <- extract_and_upload_cover(path, probe),
         {:ok, segments} <- segment_file(path, probe, original_filename),
         {:ok, segments_data} <- upload_segments(segments),
         {:ok, _} <-
           create_book_from_segments(
             segments_data,
             merge_metadata(book_metadata, probe),
             cover_s3_key
           ),
         {:ok, _} <-
           delete_from_s3(original_filename) do
      Sonnet.Library.broadcast_books_updated()
      :ok
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

  defp delete_from_s3(s3_key) do
    key = full_key(s3_key)
    ExAws.S3.delete_object(bucket(), key) |> ExAws.request()

    {:ok, :ok}
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

  defp merge_metadata(user_metadata, probe) do
    probe_metadata = extract_metadata_from_probe(probe)

    %{
      "title" => user_metadata["title"] || probe_metadata["title"],
      "author" => user_metadata["author"] || probe_metadata["author"],
      "narrator" => user_metadata["narrator"] || probe_metadata["narrator"],
      "description" => user_metadata["description"] || probe_metadata["description"]
    }
  end

  defp extract_metadata_from_probe(probe) do
    format_tags = get_in(probe, ["format", "tags"]) || %{}

    %{
      "title" => Map.get(format_tags, "title"),
      "author" => Map.get(format_tags, "artist"),
      "narrator" => Map.get(format_tags, "album_artist"),
      "description" => Map.get(format_tags, "description")
    }
  end

  defp segment_file(original_path, probe, original_filename) do
    chapters_metadata = Map.get(probe, "chapters", [])
    extension = Path.extname(original_filename) || ".m4a"

    if chapters_metadata == [] do
      segment_by_duration(original_path, extension)
    else
      segment_by_chapters(original_path, chapters_metadata, extension)
    end
  end

  defp segment_by_duration(original_path, extension) do
    output_dir = Briefly.create!(type: :directory)

    case System.cmd("ffmpeg", [
           "-i",
           original_path,
           "-map_metadata",
           "0",
           "-id3v2_version",
           "3",
           "-c:a",
           "copy",
           "-f",
           "segment",
           "-segment_time",
           Integer.to_string(@segment_duration_seconds),
           "-segment_list",
           "/dev/null",
           "-reset_timestamps",
           "1",
           Path.join(output_dir, "segment_%03d#{extension}")
         ]) do
      {_, 0} ->
        segments =
          File.ls!(output_dir)
          |> Enum.sort()
          |> Enum.map(fn filename ->
            %{
              path: Path.join(output_dir, filename),
              title: nil
            }
          end)

        {:ok, segments}

      {_, exit_code} ->
        {:error, {:segmentation_failed, exit_code}}
    end
  end

  defp segment_by_chapters(original_path, chapters_metadata, extension) do
    output_dir = Briefly.create!(type: :directory)

    segments =
      chapters_metadata
      |> Enum.with_index()
      |> Enum.map(fn {chapter_meta, index} ->
        start_time = Float.floor(String.to_float(chapter_meta["start_time"]), 3)
        end_time = Float.ceil(String.to_float(chapter_meta["end_time"]), 3)
        duration = Float.ceil(end_time - start_time, 3)

        title = Map.get(chapter_meta["tags"] || %{}, "title", "Chapter #{index + 1}")
        output_path = Path.join(output_dir, "chapter_#{index + 1}#{extension}")

        case System.cmd("ffmpeg", [
               "-ss",
               Float.to_string(start_time),
               "-i",
               original_path,
               "-t",
               Float.to_string(duration),
               "-c",
               "copy",
               "-y",
               output_path
             ]) do
          {_, 0} ->
            {:ok, %{path: output_path, title: title}}

          {_, exit_code} ->
            {:error, {:segment_failed, index, exit_code}}
        end
      end)
      |> Enum.filter(fn
        {:ok, _} -> true
        _ -> false
      end)
      |> Enum.map(fn {:ok, segment} -> segment end)

    if length(segments) == length(chapters_metadata) do
      {:ok, segments}
    else
      {:error, :not_all_segments_created}
    end
  end

  defp upload_segments(segments) do
    results =
      Enum.map(segments, fn %{path: path, title: title} ->
        hash = calculate_file_hash(path)
        extension = Path.extname(path)
        s3_key = Path.join([prefix(), "books", "#{hash}#{extension}"])

        case upload_segment(path, s3_key) do
          :ok ->
            {:ok,
             %{
               s3_key: s3_key,
               title: title,
               duration_ms: get_audio_duration(path)
             }}

          {:error, reason} ->
            {:error, {:upload_failed, reason}}
        end
      end)

    errors = Enum.filter(results, fn {status, _} -> status == :error end)

    if errors == [] do
      {:ok, Enum.map(results, fn {:ok, asset} -> asset end)}
    else
      {:error, errors}
    end
  end

  defp upload_segment(path, s3_key) do
    path
    |> ExAws.S3.Upload.stream_file()
    |> ExAws.S3.upload(bucket(), s3_key)
    |> ExAws.request()
    |> case do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_book_from_segments(segments_data, book_metadata, cover_s3_key) do
    Sonnet.Library.ingest_segmented!(segments_data, book_metadata, cover_s3_key)
  end

  defp calculate_file_hash(path) do
    File.stream!(path)
    |> Enum.reduce(:crypto.hash_init(:sha256), fn chunk, acc ->
      :crypto.hash_update(acc, chunk)
    end)
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp get_audio_duration(path) do
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
    key = Path.join([prefix(), "covers", "#{hash}.jpg"])

    path
    |> ExAws.S3.Upload.stream_file()
    |> ExAws.S3.upload(bucket(), key)
    |> ExAws.request!()

    key
  end

  defp cleanup_fatal(s3_key) do
    ExAws.S3.delete_object(bucket(), full_key(s3_key)) |> ExAws.request()
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
    Application.get_env(:sonnet, :ingest_prefix) || ""
  end

  defp full_key(s3_key) do
    Path.join(prefix(), s3_key)
  end
end
