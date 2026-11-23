defmodule Sonnet.Workers.MultiIngester do
  @moduledoc """
  Oban worker for multi-file audiobook ingestion (e.g., multiple `.mp3` chapters).

  Streams one file at a time (download -> probe -> promote to content-addressed `books/`
  key -> delete local temp file) so disk usage stays bounded, and persists the book,
  media assets, chapters, and staging cleanup jobs atomically.
  """

  use Oban.Worker,
    queue: :ingestion,
    max_attempts: 5,
    unique: [
      period: :infinity,
      keys: [:s3_keys],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  alias Sonnet.Ingestion.JobOutcome
  alias Sonnet.Library
  alias Sonnet.Media

  @impl Oban.Worker
  def perform(%Oban.Job{args: args} = job) do
    s3_keys = args["s3_keys"]
    original_filenames = args["original_filenames"]
    book_metadata = args["book_metadata"] || %{}
    delete_source_on_failure? = Map.get(args, "delete_source_on_failure", false)

    with :ok <- validate_args(s3_keys, original_filenames) do
      result =
        Media.with_temp_dir(fn work_dir ->
          ingest_multi_files(s3_keys, original_filenames, book_metadata, work_dir)
        end)

      case result do
        :ok ->
          Library.broadcast_books_updated()
          :ok

        {:error, step, reason, uploaded_keys} ->
          JobOutcome.handle_failure(job, step, reason,
            uploaded_keys: uploaded_keys,
            source_keys: s3_keys,
            delete_source_on_failure: delete_source_on_failure?
          )
      end
    else
      {:error, reason} ->
        {:cancel, {:ingestion_failed, :invalid_args, reason}}
    end
  end

  defp validate_args(s3_keys, original_filenames)
       when is_list(s3_keys) and is_list(original_filenames) and
              s3_keys != [] and length(s3_keys) == length(original_filenames) do
    if Enum.all?(s3_keys, &(is_binary(&1) and &1 != "")) and
         Enum.all?(original_filenames, &is_binary/1) do
      :ok
    else
      {:error, :invalid_file_entries}
    end
  end

  defp validate_args(_s3_keys, _original_filenames), do: {:error, :invalid_file_list}

  defp ingest_multi_files(s3_keys, original_filenames, book_metadata, work_dir) do
    sorted_files =
      Enum.zip(s3_keys, original_filenames)
      |> Enum.sort_by(fn {_s3_key, filename} -> Media.natural_sort_key(filename) end)

    with {:ok, chapters_data, first_probe, cover_s3_key, uploaded_keys} <-
           process_files(sorted_files, work_dir),
         metadata =
           Media.merge_metadata(book_metadata, first_probe || %{}, nil, prefer_album: true),
         {:ok, _changes} <-
           persist_book(chapters_data, metadata, cover_s3_key, s3_keys, uploaded_keys) do
      :ok
    end
  end

  defp process_files(sorted_files, work_dir) do
    sorted_files
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, [], nil, nil, []}, fn {{s3_key, original_filename}, index},
                                                     {:ok, chapters_acc, first_probe,
                                                      cover_s3_key, uploaded_keys} ->
      case process_single_track(s3_key, original_filename, index, first_probe == nil, work_dir) do
        {:ok, chapter, track_probe, maybe_cover_key, new_uploaded_keys} ->
          next_first_probe = first_probe || track_probe
          next_cover_key = cover_s3_key || maybe_cover_key

          {:cont,
           {:ok, [chapter | chapters_acc], next_first_probe, next_cover_key,
            uploaded_keys ++ new_uploaded_keys}}

        {:error, step, reason, partial_uploaded_keys} ->
          {:halt, {:error, step, reason, uploaded_keys ++ partial_uploaded_keys}}
      end
    end)
    |> case do
      {:ok, chapters_acc, first_probe, cover_s3_key, uploaded_keys} ->
        {:ok, Enum.reverse(chapters_acc), first_probe, cover_s3_key, uploaded_keys}

      {:error, step, reason, uploaded_keys} ->
        {:error, step, reason, uploaded_keys}
    end
  end

  defp process_single_track(s3_key, original_filename, index, extract_cover?, work_dir) do
    case Media.download_to_temp(s3_key, work_dir) do
      {:ok, local_path} ->
        try do
          with {:ok, probe} <- probe_audio(local_path),
               {:ok, duration_ms} <- parse_duration(probe),
               {:ok, cover_s3_key} <-
                 maybe_extract_cover(local_path, probe, extract_cover?, work_dir),
               cover_keys = if(cover_s3_key, do: [cover_s3_key], else: []),
               extension = Media.extension_from_probe(probe),
               {:ok, permanent_key} <- upload_track(local_path, extension, cover_keys) do
            chapter = %{
              s3_key: permanent_key,
              title: chapter_title(original_filename, index),
              duration_ms: duration_ms
            }

            {:ok, chapter, probe, cover_s3_key, cover_keys ++ [permanent_key]}
          end
        after
          File.rm(local_path)
        end

      {:error, reason} ->
        {:error, :download_failed, reason, []}
    end
  end

  defp probe_audio(path) do
    case Media.probe_file(path, false) do
      {:ok, probe} ->
        if Media.has_audio_stream?(probe) do
          {:ok, probe}
        else
          {:error, :probe_failed, {:permanent, :no_audio_stream}, []}
        end

      {:error, reason} ->
        {:error, :probe_failed, reason, []}
    end
  end

  defp parse_duration(probe) do
    case Media.parse_duration_ms(probe) do
      {:ok, duration_ms} -> {:ok, duration_ms}
      {:error, reason} -> {:error, :probe_failed, reason, []}
    end
  end

  defp maybe_extract_cover(_path, _probe, false, _work_dir), do: {:ok, nil}

  defp maybe_extract_cover(path, probe, true, work_dir) do
    case Media.extract_and_upload_embedded_cover(path, probe, work_dir) do
      {:ok, cover_s3_key} -> {:ok, cover_s3_key}
      {:error, reason} -> {:error, :cover_upload_failed, reason, []}
    end
  end

  defp upload_track(local_path, extension, existing_uploaded_keys) do
    case Media.upload_audio_file(local_path, extension) do
      {:ok, permanent_key} -> {:ok, permanent_key}
      {:error, reason} -> {:error, :track_upload_failed, reason, existing_uploaded_keys}
    end
  end

  defp persist_book(chapters_data, metadata, cover_s3_key, source_keys, uploaded_keys) do
    case Library.create_book_with_chapters(chapters_data, metadata,
           cover_s3_key: cover_s3_key,
           source_keys_to_delete: source_keys
         ) do
      {:ok, changes} ->
        {:ok, changes}

      {:error, reason} ->
        {:error, :book_creation_failed, reason, uploaded_keys}
    end
  rescue
    e in DBConnection.ConnectionError ->
      {:error, :book_creation_failed, {:transient, e}, uploaded_keys}

    e in Postgrex.Error ->
      {:error, :book_creation_failed, JobOutcome.classify_postgrex_error(e), uploaded_keys}
  end

  defp chapter_title(original_filename, index) do
    case original_filename |> Path.basename() |> Path.rootname() |> String.trim() do
      "" -> "Chapter #{index + 1}"
      title -> title
    end
  end
end
