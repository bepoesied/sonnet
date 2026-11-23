defmodule Sonnet.Ingestion.JobOutcome do
  @moduledoc """
  Shared error classification and retry-safe S3 cleanup helpers for ingestion workers.
  """

  require Logger

  alias Sonnet.Library
  alias Sonnet.Storage
  alias Sonnet.Workers.S3ObjectCleanup

  @doc """
  Returns `true` if `reason` represents a permanent (non-retryable) error.
  """
  def permanent_error?(:not_found), do: true
  def permanent_error?({:permanent, _}), do: true
  def permanent_error?({:transaction_failed, _op, %Ecto.Changeset{}, _changes}), do: true
  def permanent_error?(_), do: false

  @doc """
  Classifies a `Postgrex.Error` into `{:permanent, error}` for data/constraint
  violations (SQLSTATE classes `22`/`23`) or `{:transient, error}` otherwise.
  """
  def classify_postgrex_error(%Postgrex.Error{postgres: %{pg_code: pg_code}} = error)
      when is_binary(pg_code) do
    if String.starts_with?(pg_code, ["22", "23"]) do
      {:permanent, error}
    else
      {:transient, error}
    end
  end

  def classify_postgrex_error(error), do: {:transient, error}

  @doc """
  Handles an ingestion failure with retry-aware cleanup.

  - Preserves source objects across retryable attempts so Oban retries can succeed.
  - Deletes newly uploaded `books/`/`covers/` objects synchronously only when unreferenced
    in Postgres, preventing both retry races and corruption of shared content-addressed assets.
  - On terminal failure (permanent error or final attempt):
    - Enqueues `S3ObjectCleanup` for any newly uploaded object whose synchronous delete failed.
    - Deletes (or enqueues deletion of) `source_keys` only when `delete_source_on_failure: true`.
  - Returns `{:cancel, ...}` for permanent errors or `{:error, ...}` for transient errors.
  """
  def handle_failure(
        %Oban.Job{attempt: attempt, max_attempts: max_attempts},
        step,
        reason,
        opts \\ []
      ) do
    uploaded_keys =
      opts
      |> Keyword.get(:uploaded_keys, [])
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    source_keys =
      opts
      |> Keyword.get(:source_keys, [])
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    delete_source_on_failure? = Keyword.get(opts, :delete_source_on_failure, false)

    permanent? = permanent_error?(reason)
    terminal? = permanent? or attempt >= max_attempts

    cleanup_uploaded_keys(uploaded_keys, terminal?)

    if terminal? and delete_source_on_failure? do
      cleanup_source_keys(source_keys)
    end

    wrapped = {:ingestion_failed, step, reason}

    if permanent? do
      Logger.error("Permanent ingestion error at #{step}: #{inspect(reason)}")
      {:cancel, wrapped}
    else
      if terminal? do
        Logger.error(
          "Final ingestion attempt (#{attempt}/#{max_attempts}) failed at #{step}: #{inspect(reason)}"
        )
      else
        Logger.warning(
          "Transient ingestion error at #{step} (attempt #{attempt}/#{max_attempts}): #{inspect(reason)}"
        )
      end

      {:error, wrapped}
    end
  end

  defp cleanup_uploaded_keys(uploaded_keys, terminal?) do
    Enum.each(uploaded_keys, fn s3_key ->
      if not safe_referenced?(s3_key) do
        case Storage.delete_object(s3_key) do
          :ok ->
            :ok

          {:error, delete_reason} ->
            Logger.warning("Rollback delete failed for #{s3_key}: #{inspect(delete_reason)}")

            if terminal? do
              enqueue_cleanup(s3_key, true)
            end
        end
      end
    end)
  rescue
    e ->
      Logger.warning("Rollback cleanup failed: #{inspect(e)}")

      if terminal? do
        Enum.each(uploaded_keys, &enqueue_cleanup(&1, true))
      end
  end

  defp cleanup_source_keys(source_keys) do
    Enum.each(source_keys, fn s3_key ->
      case Storage.delete_object(s3_key) do
        :ok ->
          :ok

        {:error, delete_reason} ->
          Logger.warning("Terminal source delete failed for #{s3_key}: #{inspect(delete_reason)}")
          enqueue_cleanup(s3_key, false)
      end
    end)
  rescue
    e ->
      Logger.warning("Terminal source cleanup failed: #{inspect(e)}")
      Enum.each(source_keys, &enqueue_cleanup(&1, false))
  end

  defp safe_referenced?(s3_key) do
    Library.s3_key_referenced?(s3_key)
  rescue
    _ -> true
  end

  defp enqueue_cleanup(s3_key, only_if_unreferenced?) do
    %{
      "s3_key" => s3_key,
      "only_if_unreferenced" => only_if_unreferenced?
    }
    |> S3ObjectCleanup.new()
    |> Oban.insert()
  rescue
    e ->
      Logger.warning("Failed to enqueue S3ObjectCleanup for #{s3_key}: #{inspect(e)}")
      :ok
  end
end
