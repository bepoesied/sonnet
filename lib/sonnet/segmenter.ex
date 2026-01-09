defmodule Sonnet.Segmenter do
  @moduledoc """
  Module for segmenting audiobook files into individual chapter files.

  This module handles the conversion of single m4b files (or other formats) 
  into segmented files per chapter using codec copy. It creates individual 
  media assets for each chapter and updates chapter records accordingly.
  """

  require Logger

  alias Sonnet.Repo
  alias Sonnet.Library.Book
  alias Sonnet.Library.Chapter
  alias Sonnet.Library.MediaAsset

  # 15 minutes
  @segment_duration_seconds 900

  def segment_book(book_id, original_media_asset_id) do
    import Ecto.Query

    book = Repo.get!(Book, book_id)
    original_asset = Repo.get!(MediaAsset, original_media_asset_id)

    chapters =
      from(c in Chapter, where: c.book_id == ^book_id, order_by: c.position) |> Repo.all()

    with {:ok, original_path} <- download_from_s3(original_asset.s3_key),
         {:ok, probe} <- probe_file(original_path),
         {:ok, segments} <- segment_file(original_path, probe, chapters),
         {:ok, new_assets} <- upload_segments(segments),
         {:ok, _} <- update_chapters_with_new_assets(chapters, new_assets) do
      Logger.info("Successfully segmented book: #{book.title}")
      :ok
    else
      {:error, reason} ->
        Logger.error("Segmentation failed for book #{book_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp download_from_s3(s3_key) do
    key = full_key(s3_key)
    path = Briefly.create!(type: :path)

    case ExAws.S3.download_file(bucket(), key, path) |> ExAws.request() do
      {:ok, _} ->
        {:ok, path}

      {:error, reason} ->
        {:error, {:download_failed, reason}}
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
          {:error, reason} -> {:error, {:invalid_json, reason}}
        end

      {_, exit_code} ->
        {:error, {:probe_failed, exit_code}}
    end
  end

  defp segment_file(original_path, probe, chapters) do
    chapters_metadata = Map.get(probe, "chapters", [])
    extension = Path.extname(original_path)

    if chapters_metadata == [] do
      segment_by_duration(original_path, length(chapters), extension)
    else
      segment_by_chapters(original_path, chapters_metadata, extension)
    end
  end

  defp segment_by_duration(original_path, _num_chapters, extension) do
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
            {:ok, %{s3_key: s3_key, title: title, duration_ms: get_audio_duration(path)}}

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

  defp update_chapters_with_new_assets(chapters, new_assets) do
    Enum.zip(chapters, new_assets)
    |> Enum.with_index()
    |> Enum.reduce({:ok, nil}, fn {{chapter, asset}, index}, acc ->
      case acc do
        {:error, _} ->
          acc

        _ ->
          media_asset = Repo.insert!(%MediaAsset{s3_key: asset.s3_key})

          cumulative_start =
            Enum.take(new_assets, index) |> Enum.map(& &1.duration_ms) |> Enum.sum()

          cumulative_end = cumulative_start + asset.duration_ms

          chapter_changeset =
            Chapter.changeset(chapter, %{
              duration_ms: asset.duration_ms,
              start_ms: cumulative_start,
              end_ms: cumulative_end,
              media_asset_id: media_asset.id
            })

          case Repo.update(chapter_changeset) do
            {:ok, _} -> {:ok, nil}
            {:error, reason} -> {:error, reason}
          end
      end
    end)
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
