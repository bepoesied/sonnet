defmodule Sonnet.Workers.Ingester do
  @moduledoc """
  Oban worker for single-file audiobook ingestion (`.m4b`, `.m4a`, etc.).

  Runs on the concurrency-capped `:ingestion` queue with retry-safe cleanup.
  """

  use Oban.Worker,
    queue: :ingestion,
    max_attempts: 5,
    unique: [
      period: :infinity,
      keys: [:s3_key],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  alias Sonnet.Ingestion.JobOutcome
  alias Sonnet.Library
  alias Sonnet.Media

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"s3_key" => s3_key} = args} = job)
      when is_binary(s3_key) and s3_key != "" do
    original_filename = args["original_filename"]
    book_metadata = args["book_metadata"] || %{}
    delete_source_on_failure? = Map.get(args, "delete_source_on_failure", false)

    result =
      Media.with_temp_dir(fn work_dir ->
        ingest_single_file(s3_key, original_filename, book_metadata, work_dir)
      end)

    case result do
      :ok ->
        Library.broadcast_books_updated()
        :ok

      {:error, step, reason, uploaded_keys} ->
        JobOutcome.handle_failure(job, step, reason,
          uploaded_keys: uploaded_keys,
          source_keys: [s3_key],
          delete_source_on_failure: delete_source_on_failure?
        )
    end
  end

  def perform(%Oban.Job{args: args}) do
    {:cancel, {:ingestion_failed, :invalid_args, args}}
  end

  defp ingest_single_file(s3_key, original_filename, book_metadata, work_dir) do
    with {:ok, source_path} <- download_source(s3_key, work_dir),
         {:ok, probe} <- probe_audio(source_path),
         {:ok, cover_s3_key} <- extract_cover(source_path, probe, work_dir),
         cover_keys = if(cover_s3_key, do: [cover_s3_key], else: []),
         {:ok, segments} <- segment_audio(source_path, probe, work_dir, cover_keys),
         _ = File.rm(source_path),
         {:ok, segments_data} <- upload_segments(segments, cover_keys),
         all_uploaded_keys = cover_keys ++ Enum.map(segments_data, & &1.s3_key),
         metadata = Media.merge_metadata(book_metadata, probe, fallback_title(original_filename)),
         {:ok, _changes} <-
           persist_book(segments_data, metadata, cover_s3_key, s3_key, all_uploaded_keys) do
      :ok
    end
  end

  defp download_source(s3_key, work_dir) do
    case Media.download_to_temp(s3_key, work_dir) do
      {:ok, path} -> {:ok, path}
      {:error, reason} -> {:error, :download_failed, reason, []}
    end
  end

  defp probe_audio(path) do
    case Media.probe_file(path) do
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

  defp extract_cover(path, probe, work_dir) do
    case Media.extract_and_upload_embedded_cover(path, probe, work_dir) do
      {:ok, cover_s3_key} -> {:ok, cover_s3_key}
      {:error, reason} -> {:error, :cover_upload_failed, reason, []}
    end
  end

  defp segment_audio(path, probe, work_dir, uploaded_keys) do
    case Media.segment_file(path, probe, work_dir) do
      {:ok, segments} -> {:ok, segments}
      {:error, reason} -> {:error, :segmentation_failed, reason, uploaded_keys}
    end
  end

  defp upload_segments(segments, existing_uploaded_keys) do
    case Media.upload_segments(segments) do
      {:ok, segments_data} ->
        {:ok, segments_data}

      {:error, reason, partial_uploaded_keys} ->
        {:error, :segment_upload_failed, reason, existing_uploaded_keys ++ partial_uploaded_keys}
    end
  end

  defp persist_book(segments_data, metadata, cover_s3_key, source_s3_key, uploaded_keys) do
    case Library.create_book_with_chapters(segments_data, metadata,
           cover_s3_key: cover_s3_key,
           source_keys_to_delete: [source_s3_key]
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

  defp fallback_title(filename) when is_binary(filename) do
    case filename |> Path.basename() |> Path.rootname() |> String.trim() do
      "" -> nil
      title -> title
    end
  end

  defp fallback_title(_), do: nil
end
