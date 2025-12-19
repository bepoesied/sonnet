defmodule Sonnet.Workers.Ingester do
  use Oban.Worker, queue: :default

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"s3_key" => s3_key} = _args}) do
    path = download_from_s3!(s3_key)

    new_s3_key = calculate_hash(path)

    cond do
      s3_object_exists?(new_s3_key) ->
        delete_from_s3(s3_key)
        :ok

      true ->
        rename_in_s3(s3_key, new_s3_key)

        s3_key = new_s3_key
        probe = probe_file!(path)

        cover_s3_key =
          if has_video_stream?(probe) do
            case extract_cover(path) do
              {:ok, cover_path} ->
                hash = calculate_hash(cover_path)
                upload_cover(cover_path, hash)

              :error ->
                nil
            end
          else
            nil
          end

        media_asset = Sonnet.Library.create_media_asset!(s3_key)

        Sonnet.Library.ingest_probe!(probe, media_asset.id, cover_s3_key)

        :ok
    end
  end

  defp download_from_s3!(s3_key) do
    key = full_key(s3_key)

    path = Briefly.create!(type: :path)

    ExAws.S3.download_file(bucket(), key, path)
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

  defp has_video_stream?(%{"streams" => streams}) do
    Enum.any?(streams, fn stream -> stream["codec_type"] == "video" end)
  end

  defp calculate_hash(path) do
    File.stream!(path)
    |> Enum.reduce(:crypto.hash_init(:sha256), fn chunk, acc ->
      :crypto.hash_update(acc, chunk)
    end)
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp extract_cover(path) do
    output_path = Briefly.create!(type: :path, extname: ".jpg")

    case System.cmd("ffmpeg", ["-i", path, "-frames:v", "1", "-f", "image2", output_path, "-y"]) do
      {_, 0} ->
        if File.exists?(output_path) and File.stat!(output_path).size > 0 do
          {:ok, output_path}
        else
          :error
        end

      {_, _} ->
        :error
    end
  end

  defp upload_cover(path, hash) do
    key = "#{prefix()}/covers/#{hash}.jpg"

    path
    |> ExAws.S3.Upload.stream_file()
    |> ExAws.S3.upload(bucket(), key)
    |> ExAws.request!()

    key
  end

  defp s3_object_exists?(s3_key) do
    key = full_key(s3_key)

    case ExAws.S3.head_object(bucket(), key) |> ExAws.request() do
      {:ok, _} -> true
      {:error, {:http_error, 404, _}} -> false
      {:error, reason} -> raise "failed to check s3 object existence: #{inspect(reason)}"
    end
  end

  defp rename_in_s3(old_s3_key, new_s3_key) do
    old_key = full_key(old_s3_key)
    new_key = full_key(new_s3_key)

    ExAws.S3.put_object_copy(bucket(), new_key, bucket(), old_key)
    |> ExAws.request!()

    ExAws.S3.delete_object(bucket(), old_key)
    |> ExAws.request!()
  end

  defp delete_from_s3(s3_key) do
    key = full_key(s3_key)

    ExAws.S3.delete_object(bucket(), key)
    |> ExAws.request!()
  end

  defp bucket do
    Application.get_env(:sonnet, :ingest_bucket)
  end

  defp prefix do
    Application.get_env(:sonnet, :ingest_prefix)
  end

  defp full_key(s3_key) do
    "#{prefix()}/#{s3_key}"
  end
end
