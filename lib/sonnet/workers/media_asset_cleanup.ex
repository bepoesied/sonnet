defmodule Sonnet.Workers.MediaAssetCleanup do
  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger

  @doc """
  Schedule a media asset cleanup job.
  """
  def schedule_cleanup(opts \\ []) do
    batch_size = Keyword.get(opts, :batch_size, 100)

    args = %{
      "batch_size" => batch_size
    }

    %{args: args}
    |> __MODULE__.new()
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    batch_size = args["batch_size"] || 100

    Logger.info("Starting orphaned media asset scan (batch_size: #{batch_size})")

    orphaned_assets = find_orphaned_media_assets(limit: batch_size)

    Logger.info(
      "Found #{length(orphaned_assets)} orphaned media assets, fanning out cleanup tasks"
    )

    Enum.each(orphaned_assets, fn asset ->
      schedule_single_cleanup(asset.id)
    end)

    :ok
  end

  defp find_orphaned_media_assets(opts) do
    import Ecto.Query

    limit = Keyword.get(opts, :limit, 100)

    query =
      from(ma in Sonnet.Library.MediaAsset,
        left_join: c in Sonnet.Library.Chapter,
        on: c.media_asset_id == ma.id,
        where: is_nil(c.id),
        limit: ^limit
      )

    Sonnet.Repo.all(query)
  end

  defp schedule_single_cleanup(media_asset_id) do
    %{"media_asset_id" => media_asset_id}
    |> Sonnet.Workers.MediaAssetCleanupSingle.new()
    |> Oban.insert()
  end
end
