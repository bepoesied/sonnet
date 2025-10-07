defmodule Sonnet.S3 do
  alias ExAws.S3

  defmodule Info do
    @enforce_keys [:bucket, :key, :size, :etag, :last_modified]
    defstruct [
      :bucket,
      :key,
      :size,
      :etag,
      :last_modified,
      :content_type
    ]
  end

  @spec stat(binary(), binary()) ::
          {:ok, Info.t()}
          | {:error, :not_found | :forbidden | term()}
  def stat(bucket, key) do
    with {:ok, resp} <- S3.head_object(bucket, key) |> ExAws.request() do
      headers = Map.get(resp, :headers, [])

      h = fn name ->
        headers
        |> Enum.find_value(fn
          {^name, v} -> v
          _ -> nil
        end)
      end

      size =
        case h.("Content-Length") do
          nil -> 0
          v -> String.to_integer(v)
        end

      info = %Info{
        bucket: bucket,
        key: key,
        size: size,
        etag: h.("ETag"),
        last_modified: h.("Last-Modified"),
        content_type: h.("Content-Type")
      }

      {:ok, info}
    else
      {:error, {:http_error, 404, _}} -> {:error, :not_found}
      {:error, {:http_error, 403, _}} -> {:error, :forbidden}
      {:error, reason} -> {:error, reason}
    end
  end
end
