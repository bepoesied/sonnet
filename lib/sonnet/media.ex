defmodule Sonnet.Media do
  @moduledoc """
  Media file helpers used by ingestion and library cover uploads.
  """

  require Logger

  @segment_duration_seconds 900
  @hash_chunk_size 65_536

  @doc """
  Runs `fun` with a dedicated temporary workspace directory and guarantees
  that the directory and all its contents are removed when `fun` exits.
  """
  def with_temp_dir(fun) when is_function(fun, 1) do
    dir = Briefly.create!(type: :directory)

    try do
      fun.(dir)
    after
      File.rm_rf(dir)
    end
  end

  def download_to_temp(s3_key, work_dir \\ nil) do
    path =
      if work_dir do
        Path.join(work_dir, "source_#{Ecto.UUID.generate()}")
      else
        Briefly.create!(type: :path)
      end

    Sonnet.Storage.download_file(s3_key, path)
  end

  def probe_file(path, show_chapters \\ true) do
    args = [
      "-v",
      "quiet",
      "-print_format",
      "json",
      "-show_format",
      "-show_streams"
    ]

    args = if show_chapters, do: args ++ ["-show_chapters"], else: args

    case System.cmd("ffprobe", args ++ [path]) do
      {output, 0} ->
        case Jason.decode(output) do
          {:ok, decoded} -> {:ok, decoded}
          {:error, reason} -> {:error, {:permanent, {:invalid_probe_json, reason}}}
        end

      {_, exit_code} ->
        {:error, {:permanent, {:ffprobe_failed, exit_code}}}
    end
  end

  def has_audio_stream?(%{"streams" => streams}) when is_list(streams) do
    Enum.any?(streams, fn stream -> stream["codec_type"] == "audio" end)
  end

  def has_audio_stream?(_probe), do: false

  def parse_duration_ms(%{"format" => %{"duration" => duration}}) when is_binary(duration) do
    case parse_float(duration) do
      {:ok, seconds} when seconds > 0 -> {:ok, floor(seconds * 1000)}
      _ -> {:error, {:permanent, :invalid_duration}}
    end
  end

  def parse_duration_ms(%{"format" => %{"duration" => duration}})
      when is_number(duration) and duration > 0 do
    {:ok, floor(duration * 1000)}
  end

  def parse_duration_ms(_probe), do: {:error, {:permanent, :invalid_duration}}

  def duration_ms(path) do
    with {:ok, probe} <- probe_file(path, false),
         {:ok, ms} <- parse_duration_ms(probe) do
      ms
    else
      _ -> 0
    end
  end

  def duration_ms_from_probe(probe) do
    case parse_duration_ms(probe) do
      {:ok, ms} -> ms
      {:error, _} -> 0
    end
  end

  def metadata_from_probe(probe, opts \\ []) do
    prefer_album? = Keyword.get(opts, :prefer_album, false)

    format_tags =
      (get_in(probe, ["format", "tags"]) || %{})
      |> Map.new(fn {k, v} -> {String.downcase(to_string(k)), v} end)

    title =
      if prefer_album? do
        empty_string_to_nil(Map.get(format_tags, "album")) ||
          empty_string_to_nil(Map.get(format_tags, "title"))
      else
        empty_string_to_nil(Map.get(format_tags, "title")) ||
          empty_string_to_nil(Map.get(format_tags, "album"))
      end

    %{
      "title" => title,
      "author" => Map.get(format_tags, "artist"),
      "narrator" => Map.get(format_tags, "album_artist"),
      "description" => Map.get(format_tags, "description")
    }
  end

  def merge_metadata(user_metadata, probe, fallback_title \\ nil, opts \\ []) do
    user_metadata = user_metadata || %{}
    probe_metadata = metadata_from_probe(probe, opts)

    %{
      "title" =>
        empty_string_to_nil(user_metadata["title"]) ||
          empty_string_to_nil(probe_metadata["title"]) ||
          empty_string_to_nil(fallback_title) ||
          "Untitled Book",
      "author" =>
        empty_string_to_nil(user_metadata["author"]) ||
          empty_string_to_nil(probe_metadata["author"]),
      "narrator" =>
        empty_string_to_nil(user_metadata["narrator"]) ||
          empty_string_to_nil(probe_metadata["narrator"]),
      "description" =>
        empty_string_to_nil(user_metadata["description"]) ||
          empty_string_to_nil(probe_metadata["description"])
    }
  end

  @doc """
  Computes a case-insensitive natural sort key so `"Chapter 2.mp3"` sorts before `"Chapter 10.mp3"`.
  """
  def natural_sort_key(filename) when is_binary(filename) do
    filename
    |> String.downcase()
    |> then(&Regex.split(~r/(\d+)/, &1, include_captures: true, trim: true))
    |> Enum.map(fn part ->
      case Integer.parse(part) do
        {num, ""} -> {0, num}
        _ -> {1, part}
      end
    end)
  end

  def extension_from_probe(probe) do
    case get_in(probe, ["format", "format_name"]) do
      nil -> ".m4b"
      name when name in ["mov,mp4,m4a,3gp,3g2,mj2", "mp4", "m4a", "mov"] -> ".m4b"
      name when name in ["mp3"] -> ".mp3"
      name when name in ["ogg", "oga"] -> ".ogg"
      name when name in ["flac"] -> ".flac"
      _ -> ".m4b"
    end
  end

  def segment_file(original_path, probe, work_dir \\ nil) do
    chapters_metadata = Map.get(probe, "chapters", [])
    extension = extension_from_probe(probe)
    output_dir = create_output_dir(work_dir)

    case parse_positive_chapters(chapters_metadata) do
      {:ok, []} ->
        segment_by_duration(original_path, extension, output_dir)

      {:ok, parsed_chapters} ->
        segment_by_chapters(original_path, parsed_chapters, extension, output_dir)

      {:error, reason} ->
        {:error, reason}
    end
  end

  def upload_audio_file(path, extension \\ nil) do
    hash = file_hash(path)
    ext = extension || Path.extname(path)
    s3_key = Path.join(["books", "#{hash}#{ext}"])

    case Sonnet.Storage.upload_file(path, s3_key) do
      :ok -> {:ok, s3_key}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Probes and uploads segmented audio files to content-addressed `books/` keys.

  Fails fast on the first error and returns `{:error, reason, uploaded_keys}` so
  callers can safely clean up any segments already uploaded during this attempt.
  """
  def upload_segments(segments) do
    Enum.reduce_while(segments, {:ok, [], []}, fn %{path: path, title: title},
                                                  {:ok, uploaded_segments, uploaded_keys} ->
      with {:ok, probe} <- probe_file(path, false),
           {:ok, duration_ms} <- parse_duration_ms(probe),
           {:ok, s3_key} <- upload_audio_file(path) do
        File.rm(path)

        segment = %{
          s3_key: s3_key,
          title: title,
          duration_ms: duration_ms
        }

        {:cont, {:ok, [segment | uploaded_segments], [s3_key | uploaded_keys]}}
      else
        {:error, reason} ->
          {:halt, {:error, reason, Enum.reverse(uploaded_keys)}}
      end
    end)
    |> case do
      {:ok, uploaded_segments, _uploaded_keys} ->
        {:ok, Enum.reverse(uploaded_segments)}

      {:error, reason, uploaded_keys} ->
        {:error, reason, uploaded_keys}
    end
  end

  @doc """
  Extracts and uploads an embedded cover image if present.

  Returns `{:ok, s3_key | nil}` or `{:error, storage_error_reason}` if uploading
  the extracted cover to S3 fails.
  """
  def extract_and_upload_embedded_cover(path, probe, work_dir \\ nil) do
    if has_video_stream?(probe) do
      case extract_cover(path, work_dir) do
        {:ok, cover_path} ->
          try do
            upload_cover(cover_path)
          after
            File.rm(cover_path)
          end

        {:error, reason} ->
          Logger.warning("Failed to extract embedded cover from #{path}: #{inspect(reason)}")
          {:ok, nil}
      end
    else
      {:ok, nil}
    end
  end

  def process_cover_upload(path, client_name) do
    with_temp_dir(fn work_dir ->
      temp_path = Path.join(work_dir, "upload#{Path.extname(client_name)}")
      File.cp!(path, temp_path)

      jpg_path = convert_to_jpg!(temp_path, work_dir)
      upload_cover!(jpg_path)
    end)
  end

  def file_hash(path) do
    File.stream!(path, @hash_chunk_size)
    |> Enum.reduce(:crypto.hash_init(:sha256), fn chunk, acc ->
      :crypto.hash_update(acc, chunk)
    end)
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp empty_string_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp empty_string_to_nil(value), do: value

  defp parse_float(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {float, ""} -> {:ok, float}
      _ -> :error
    end
  end

  defp parse_float(value) when is_number(value), do: {:ok, value * 1.0}
  defp parse_float(_), do: :error

  defp create_output_dir(nil), do: Briefly.create!(type: :directory)

  defp create_output_dir(work_dir) do
    dir = Path.join(work_dir, "segments_#{Ecto.UUID.generate()}")
    File.mkdir_p!(dir)
    dir
  end

  defp segment_by_duration(original_path, extension, output_dir) do
    output_pattern = Path.join(output_dir, "segment_%04d#{extension}")

    format_opts =
      if extension == ".m4b" do
        ["-segment_format_options", "movflags=+faststart"]
      else
        []
      end

    args =
      [
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
        "make_zero"
      ] ++ format_opts ++ ["-y", output_pattern]

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
          {:error, {:permanent, {:no_segments_created, output}}}
        else
          {:ok, segments}
        end

      {output, exit_code} ->
        {:error, {:permanent, {:segmentation_failed, exit_code, output}}}
    end
  end

  defp parse_positive_chapters(chapters_metadata) do
    chapters_metadata
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {chapter_meta, index}, {:ok, acc} ->
      with {:ok, start_time} <- parse_float(chapter_meta["start_time"]),
           {:ok, end_time} <- parse_float(chapter_meta["end_time"]) do
        if end_time > start_time do
          title =
            chapter_meta["tags"]
            |> Kernel.||(%{})
            |> Map.get("title")
            |> empty_string_to_nil()

          {:cont, {:ok, [{start_time, end_time - start_time, title} | acc]}}
        else
          Logger.info(
            "Skipping zero-duration chapter marker at index #{index} (#{start_time}..#{end_time})"
          )

          {:cont, {:ok, acc}}
        end
      else
        :error ->
          {:halt, {:error, {:permanent, {:invalid_chapter_timing, index, chapter_meta}}}}
      end
    end)
    |> case do
      {:ok, chapters} -> {:ok, Enum.reverse(chapters)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp segment_by_chapters(original_path, parsed_chapters, extension, output_dir) do
    movflags = if extension == ".m4b", do: ["-movflags", "+faststart"], else: []

    parsed_chapters
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {{start_time, duration, raw_title}, index}, {:ok, acc} ->
      start_s = :erlang.float_to_binary(start_time, decimals: 3)
      dur_s = :erlang.float_to_binary(duration, decimals: 3)
      title = raw_title || "Chapter #{index + 1}"
      output_path = Path.join(output_dir, "chapter_#{index + 1}#{extension}")

      args =
        [
          "-ss",
          start_s,
          "-i",
          original_path,
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
          "make_zero"
        ] ++ movflags ++ ["-y", output_path]

      case System.cmd("ffmpeg", args, stderr_to_stdout: true) do
        {_, 0} ->
          {:cont, {:ok, [%{path: output_path, title: title} | acc]}}

        {output, exit_code} ->
          {:halt, {:error, {:permanent, {:segment_failed, index, exit_code, output}}}}
      end
    end)
    |> case do
      {:ok, segments} -> {:ok, Enum.reverse(segments)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp has_video_stream?(%{"streams" => streams}) when is_list(streams) do
    Enum.any?(streams, fn stream -> stream["codec_type"] == "video" end)
  end

  defp has_video_stream?(_probe), do: false

  defp extract_cover(path, work_dir) do
    output_path =
      if work_dir do
        Path.join(work_dir, "cover_#{Ecto.UUID.generate()}.jpg")
      else
        Briefly.create!(type: :path, extname: ".jpg")
      end

    args = [
      "-i",
      path,
      "-an",
      "-frames:v",
      "1",
      "-vf",
      "scale='min(800,iw)':-2",
      "-q:v",
      "3",
      "-f",
      "image2",
      "-y",
      output_path
    ]

    case System.cmd("ffmpeg", args, stderr_to_stdout: true) do
      {_, 0} ->
        if File.exists?(output_path) and File.stat!(output_path).size > 0 do
          {:ok, output_path}
        else
          File.rm(output_path)
          {:error, :empty_cover}
        end

      {output, exit_code} ->
        File.rm(output_path)
        {:error, {:ffmpeg_failed, exit_code, output}}
    end
  end

  defp convert_to_jpg!(input_path, work_dir) do
    output_path = Path.join(work_dir, "cover_#{Ecto.UUID.generate()}.jpg")

    case System.cmd(
           "ffmpeg",
           [
             "-i",
             input_path,
             "-vf",
             "scale='min(800,iw)':-2",
             "-q:v",
             "3",
             "-f",
             "image2",
             "-y",
             output_path
           ],
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        if File.exists?(output_path) and File.stat!(output_path).size > 0 do
          output_path
        else
          raise "Failed to convert cover to JPG"
        end

      {error, _} ->
        raise "FFmpeg error: #{error}"
    end
  end

  defp upload_cover(path) do
    hash = file_hash(path)
    key = Path.join(["covers", "#{hash}.jpg"])

    case Sonnet.Storage.upload_file(path, key) do
      :ok -> {:ok, key}
      {:error, reason} -> {:error, reason}
    end
  end

  defp upload_cover!(path) do
    hash = file_hash(path)
    key = Path.join(["covers", "#{hash}.jpg"])
    Sonnet.Storage.upload_file!(path, key)
  end
end
