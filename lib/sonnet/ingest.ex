defmodule Sonnet.Ingest do
  use GenServer

  alias ExAws.S3

  @type state :: %{
          bucket: String.t(),
          prefix: String.t() | nil,
          last_scan_at: DateTime.t() | nil
        }

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def scan_now(opts \\ []) do
    GenServer.call(__MODULE__, {:scan_now, opts})
  end

  def scan_async(opts \\ []) do
    GenServer.cast(__MODULE__, {:scan_now, opts})
  end

  @impl true
  def init(opts) do
    bucket = Keyword.fetch!(opts, :bucket)
    prefix = Keyword.get(opts, :prefix)

    state = %{
      bucket: bucket,
      prefix: prefix,
      last_scan_at: nil
    }

    Process.send_after(self(), :startup_scan, 0)
    {:ok, state}
  end

  @impl true
  def handle_info(:startup_scan, state) do
    scan_async()
    {:noreply, state}
  end

  @impl true
  def handle_call({:scan_now, opts}, _from, state) do
    bucket = Keyword.get(opts, :bucket, state.bucket)
    prefix = Keyword.get(opts, :prefix, state.prefix)

    do_scan(bucket, prefix)
    {:noreply, %{state | last_scan_at: DateTime.utc_now()}}
  end

  @impl true
  def handle_cast({:scan_now, opts}, state) do
    bucket = Keyword.get(opts, :bucket, state.bucket)
    prefix = Keyword.get(opts, :prefix, state.prefix)

    do_scan(bucket, prefix)
    {:noreply, %{state | last_scan_at: DateTime.utc_now()}}
  end

  defp do_scan(bucket, prefix) do
    S3.list_objects_v2(bucket, prefix: prefix)
    |> ExAws.stream!()
    |> Stream.filter(&filter_books/1)
    |> Enum.reduce(MapSet.new(), fn entry, acc ->
      MapSet.put(acc, deduplicate_books(bucket, entry))
    end)
    |> MapSet.to_list()
    |> Sonnet.Content.ingest_books()
  end

  defp filter_books(%{key: key}) do
    String.ends_with?(key, [".m4b"])
  end

  defp extract_name(key) do
    path =
      String.split(key, "/")
      |> Enum.reverse()

    case path do
      [_last, second | _] -> second
      _ -> nil
    end
  end

  defp deduplicate_books(bucket, %{key: key}) do
    name = extract_name(key)

    [
      name: name,
      path: key,
      bucket: bucket,
      inserted_at: DateTime.utc_now() |> DateTime.truncate(:second),
      updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
    ]
  end
end
