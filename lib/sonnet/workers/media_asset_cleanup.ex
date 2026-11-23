defmodule Sonnet.Workers.MediaAssetCleanup do
  @moduledoc """
  Periodic worker that scans for orphaned `MediaAsset` records (no referencing chapters
  older than the grace period) and enqueues per-asset cleanup jobs.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [
      period: 300,
      states: [:available, :scheduled, :executing]
    ]

  import Ecto.Query

  require Logger

  @default_batch_size 100
  @default_grace_period_minutes 60

  @doc """
  Schedule a media asset cleanup job.
  """
  def schedule_cleanup(opts \\ []) do
    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)
    grace_period_minutes = Keyword.get(opts, :grace_period_minutes, @default_grace_period_minutes)

    %{
      "batch_size" => batch_size,
      "grace_period_minutes" => grace_period_minutes
    }
    |> __MODULE__.new()
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    batch_size = args["batch_size"] || @default_batch_size
    grace_period_minutes = args["grace_period_minutes"] || @default_grace_period_minutes

    Logger.info(
      "Starting orphaned media asset scan (batch_size: #{batch_size}, grace_period_minutes: #{grace_period_minutes})"
    )

    orphaned_assets =
      find_orphaned_media_assets(
        limit: batch_size,
        grace_period_minutes: grace_period_minutes
      )

    Logger.info(
      "Found #{length(orphaned_assets)} orphaned media assets, fanning out cleanup tasks"
    )

    Enum.each(orphaned_assets, fn asset ->
      schedule_single_cleanup(asset.id)
    end)

    :ok
  end

  defp find_orphaned_media_assets(opts) do
    limit = Keyword.get(opts, :limit, @default_batch_size)
    grace_period_minutes = Keyword.get(opts, :grace_period_minutes, @default_grace_period_minutes)
    cutoff = DateTime.add(DateTime.utc_now(), -grace_period_minutes, :minute)

    query =
      from(ma in Sonnet.Library.MediaAsset,
        left_join: c in Sonnet.Library.Chapter,
        on: c.media_asset_id == ma.id,
        where: is_nil(c.id) and ma.inserted_at < ^cutoff,
        order_by: [asc: ma.inserted_at],
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
