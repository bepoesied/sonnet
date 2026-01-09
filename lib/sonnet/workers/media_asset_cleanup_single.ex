defmodule Sonnet.Workers.MediaAssetCleanupSingle do
  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"media_asset_id" => media_asset_id}}) do
    asset = Sonnet.Repo.get(Sonnet.Library.MediaAsset, media_asset_id)

    cond do
      is_nil(asset) ->
        Logger.warning("Media asset #{media_asset_id} no longer exists, skipping")
        :ok

      s3_object_exists?(asset.s3_key) ->
        Logger.info("Deleting orphaned media asset #{media_asset_id} from S3 and DB")
        delete_from_s3_and_db(asset)

      true ->
        Logger.info(
          "Media asset #{media_asset_id} (#{asset.s3_key}) not in S3, deleting from DB only"
        )

        Sonnet.Repo.delete!(asset)
        :ok
    end
  end

  defp s3_object_exists?(s3_key) do
    bucket = Application.get_env(:sonnet, :ingest_bucket)

    case ExAws.S3.head_object(bucket, s3_key) |> ExAws.request() do
      {:ok, _} ->
        true

      {:error, {:http_error, 404, _}} ->
        false

      {:error, reason} ->
        Logger.warning("Error checking S3 object existence (#{s3_key}): #{inspect(reason)}")
        false
    end
  end

  defp delete_from_s3_and_db(asset) do
    case delete_from_s3(asset.s3_key) do
      :ok ->
        Sonnet.Repo.delete!(asset)
        Logger.info("Successfully deleted media asset #{asset.id} from S3 and DB")
        :ok

      {:error, reason} ->
        Logger.warning("Failed to delete from S3 (#{asset.s3_key}): #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp delete_from_s3(s3_key) do
    bucket = Application.get_env(:sonnet, :ingest_bucket)

    case ExAws.S3.delete_object(bucket, s3_key) |> ExAws.request() do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
