defmodule Sonnet.Workers.Ingester do
  use Oban.Worker, queue: :default, max_attempts: 3

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
         {:ok, segments} <- segment_file(path, probe, []),
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
    path = Briefly.create!(type: :path)
    Sonnet.Storage.download_file(s3_key, path)
  end

  defp delete_from_s3(s3_key) do
    Sonnet.Storage.delete_object(s3_key)
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
      "title" =>
        empty_string_to_nil(user_metadata["title"]) || probe_metadata["title"] || "Untitled Book",
      "author" => empty_string_to_nil(user_metadata["author"]) || probe_metadata["author"],
      "narrator" => empty_string_to_nil(user_metadata["narrator"]) || probe_metadata["narrator"],
      "description" =>
        empty_string_to_nil(user_metadata["description"]) || probe_metadata["description"]
    }
  end

  defp empty_string_to_nil(""), do: nil
  defp empty_string_to_nil(value), do: value

  defp extract_metadata_from_probe(probe) do
    format_tags = get_in(probe, ["format", "tags"]) || %{}

    %{
      "title" => Map.get(format_tags, "title"),
      "author" => Map.get(format_tags, "artist"),
      "narrator" => Map.get(format_tags, "album_artist"),
      "description" => Map.get(format_tags, "description")
    }
  end

  defp segment_file(original_path, probe, chapters) do
    chapters_metadata = Map.get(probe, "chapters", [])
    extension = get_extension_from_probe(probe)

    if chapters_metadata == [] do
      segment_by_duration(original_path, length(chapters), extension)
    else
      segment_by_chapters(original_path, chapters_metadata, extension)
    end
  end

  defp get_extension_from_probe(probe) do
    case get_in(probe, ["format", "format_name"]) do
      nil ->
        ".m4b"

      format_name ->
        case format_name do
          name when name in ["mov,mp4,m4a,3gp,3g2,mj2", "mp4", "m4a", "mov"] -> ".m4b"
          name when name in ["mp3"] -> ".mp3"
          name when name in ["ogg", "oga"] -> ".ogg"
          name when name in ["flac"] -> ".flac"
          _ -> ".m4b"
        end
    end
  end

  defp segment_by_duration(original_path, extension) do
    output_dir = Briefly.create!(type: :directory)
    output_pattern = Path.join(output_dir, "segment_%03d#{extension}")

    args = [
      "-i",
      original_path,
      "-map",
      "0:a:0",
      "-vn",
      "-c",
      "copy",
      "-f",
      "segment",
      "-segment_time",
      Integer.to_string(@segment_duration_seconds),
      "-segment_list",
      "/dev/null",
      "-reset_timestamps",
      "1",
      "-fflags",
      "+genpts",
      "-avoid_negative_ts",
      "make_zero",
      "-movflags",
      "+faststart",
      "-y",
      output_pattern
    ]

    case System.cmd("ffmpeg", args, stderr_to_stdout: true) do
      {output, 0} ->
        segments =
          output_dir
          |> File.ls!()
          |> Enum.sort()
          |> Enum.filter(&String.ends_with?(&1, extension))
          |> Enum.map(fn filename ->
            %{
              path: Path.join(output_dir, filename),
              title: nil
            }
          end)

        if segments == [] do
          {:error, {:no_segments_created, output}}
        else
          {:ok, segments}
        end

      {output, exit_code} ->
        {:error, {:segmentation_failed, exit_code, output}}
    end
  end

  defp segment_by_chapters(original_path, chapters_metadata, extension) do
    output_dir = Briefly.create!(type: :directory)

    segments =
      chapters_metadata
      |> Enum.with_index()
      |> Enum.map(fn {chapter_meta, index} ->
        start_time = String.to_float(chapter_meta["start_time"])
        end_time = String.to_float(chapter_meta["end_time"])
        duration = max(end_time - start_time, 0.001)

        start_s = :erlang.float_to_binary(start_time, decimals: 3)
        dur_s = :erlang.float_to_binary(duration, decimals: 3)

        title = Map.get(chapter_meta["tags"] || %{}, "title", "Chapter #{index + 1}")
        output_path = Path.join(output_dir, "chapter_#{index + 1}#{extension}")

        case System.cmd("ffmpeg", [
               "-i",
               original_path,
               "-ss",
               start_s,
               "-t",
               dur_s,
               "-map",
               "0:a:0",
               "-vn",
               "-c",
               "copy",
               "-fflags",
               "+genpts",
               "-avoid_negative_ts",
               "make_zero",
               "-movflags",
               "+faststart",
               "-y",
               output_path
             ]) do
          {_, 0} ->
            {:ok, %{path: output_path, title: title}}

          {stderr_or_stdout, exit_code} ->
            {:error, {:segment_failed, index, exit_code, stderr_or_stdout}}
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
        s3_key = Path.join([Sonnet.Storage.prefix(), "books", "#{hash}#{extension}"])

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
    Sonnet.Storage.upload_file(path, s3_key)
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
    key = Path.join([Sonnet.Storage.prefix(), "covers", "#{hash}.jpg"])
    Sonnet.Storage.upload_file!(path, key)
  end

  defp cleanup_fatal(s3_key) do
    Sonnet.Storage.delete_object(s3_key)
    Sonnet.Library.delete_media_asset_by_s3_key(s3_key)
    :ok
  rescue
    e ->
      Logger.warning("Cleanup failed for #{s3_key}: #{inspect(e)}")
      :ok
  end
end
