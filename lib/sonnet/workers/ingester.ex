defmodule Sonnet.Workers.Ingester do
  use Oban.Worker, queue: :default

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"s3_key" => s3_key} = _args}) do
    s3_key
    |> download_from_s3!()
    |> probe_file!()
    |> dbg()

    :ok
  end

  defp download_from_s3!(s3_key) do
    bucket = Application.get_env(:sonnet, :ingest_bucket)
    prefix = Application.get_env(:sonnet, :ingest_prefix)
    key = "#{prefix}/#{s3_key}"

    path = Briefly.create!(type: :path)

    ExAws.S3.download_file(bucket, key, path)
    |> ExAws.request!()

    path
  end

  defp probe_file!(path) do
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
      {output, 0} -> Jason.decode!(output)
      {_, _} -> raise "failed to probe file"
    end
  end
end
