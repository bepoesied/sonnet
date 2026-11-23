defmodule Sonnet.Workers.MediaAssetCleanupSingle do
  @moduledoc """
  Deletes a single orphaned `MediaAsset` from S3 and Postgres.

  Re-verifies that no `Chapter` references the asset before deleting from S3, and
  uses a guarded DB delete so concurrently attached chapters can never be cascade-deleted.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 5,
    unique: [
      period: :infinity,
      keys: [:media_asset_id],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  import Ecto.Query

  require Logger

  alias Sonnet.Library.Chapter
  alias Sonnet.Library.MediaAsset
  alias Sonnet.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"media_asset_id" => media_asset_id}}) do
    case Repo.get(MediaAsset, media_asset_id) do
      nil ->
        Logger.info("Media asset #{media_asset_id} no longer exists, skipping")
        :ok

      asset ->
        if referenced_by_any_chapter?(asset.id) do
          Logger.info("Media asset #{asset.id} is referenced by a chapter, skipping cleanup")
          :ok
        else
          delete_from_s3_and_db(asset)
        end
    end
  end

  def perform(%Oban.Job{args: args}) do
    {:cancel, {:invalid_args, args}}
  end

  defp referenced_by_any_chapter?(media_asset_id) do
    Repo.exists?(from c in Chapter, where: c.media_asset_id == ^media_asset_id)
  end

  defp delete_from_s3_and_db(asset) do
    case Sonnet.Storage.delete_object(asset.s3_key) do
      :ok ->
        {deleted_count, _} =
          from(ma in MediaAsset,
            as: :ma,
            where: ma.id == ^asset.id,
            where: not exists(from(c in Chapter, where: c.media_asset_id == parent_as(:ma).id))
          )
          |> Repo.delete_all()

        if deleted_count == 1 do
          Logger.info("Successfully deleted orphaned media asset #{asset.id} from S3 and DB")
        else
          Logger.info("Skipped DB deletion for media asset #{asset.id}: no longer orphaned")
        end

        :ok

      {:error, {:permanent, reason}} ->
        Logger.error(
          "Permanent error deleting media asset #{asset.id} (#{asset.s3_key}) from S3: #{inspect(reason)}"
        )

        {:cancel, reason}

      {:error, reason} ->
        Logger.warning(
          "Transient error deleting media asset #{asset.id} (#{asset.s3_key}) from S3: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end
end
