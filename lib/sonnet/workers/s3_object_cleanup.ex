defmodule Sonnet.Workers.S3ObjectCleanup do
  @moduledoc """
  Asynchronously deletes an S3 object with retries.

  When `"only_if_unreferenced"` is `true` (the default), the worker checks
  Postgres before deleting so content-addressed `books/` or `covers/` objects
  referenced by any active chapter or book are never removed.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 5,
    unique: [
      period: :infinity,
      keys: [:s3_key, :only_if_unreferenced],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"s3_key" => s3_key} = args}) when is_binary(s3_key) do
    only_if_unreferenced? = Map.get(args, "only_if_unreferenced", true)

    if only_if_unreferenced? and Sonnet.Library.s3_key_referenced?(s3_key) do
      Logger.info("Skipping S3 deletion for #{s3_key}: still referenced in library")
      :ok
    else
      case Sonnet.Storage.delete_object(s3_key) do
        :ok ->
          :ok

        {:error, {:permanent, reason}} ->
          Logger.error("Permanent error deleting S3 object #{s3_key}: #{inspect(reason)}")
          {:cancel, reason}

        {:error, reason} ->
          Logger.warning("Transient error deleting S3 object #{s3_key}: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  def perform(%Oban.Job{args: args}) do
    {:cancel, {:invalid_args, args}}
  end
end
