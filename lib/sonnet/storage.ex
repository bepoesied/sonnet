defmodule Sonnet.Storage do
  @moduledoc """
  Storage context for managing S3 operations.
  """

  @type error_reason :: :not_found | {:transient, term()} | {:permanent, term()}

  @doc """
  Downloads a file from S3 to the specified local path.

  Returns `{:ok, path}` on success, `{:error, :not_found}` if the object doesn't exist,
  `{:error, {:permanent, reason}}` for non-retryable client errors, or
  `{:error, {:transient, reason}}` for retryable failures.
  """
  def download_file(s3_key, local_path) do
    case object_exists(s3_key) do
      {:ok, false} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}

      {:ok, true} ->
        key = full_key(s3_key)

        try do
          case ExAws.S3.download_file(bucket(), key, local_path) |> ExAws.request() do
            {:ok, _} ->
              {:ok, local_path}

            {:error, reason} ->
              File.rm(local_path)
              {:error, classify_error(reason)}
          end
        catch
          :exit, reason ->
            File.rm(local_path)
            {:error, {:transient, {:exit, reason}}}
        end
    end
  end

  @doc """
  Uploads a local file to S3.

  Returns `:ok` on success or `{:error, error_reason}` on failure.
  """
  def upload_file(local_path, s3_key) do
    key = full_key(s3_key)

    try do
      result =
        local_path
        |> ExAws.S3.Upload.stream_file()
        |> ExAws.S3.upload(bucket(), key)
        |> ExAws.request()

      case result do
        {:ok, %{status_code: status}} when status in 200..299 ->
          :ok

        {:ok, %{status_code: status} = resp} ->
          {:error, classify_error({:http_error, status, resp})}

        {:error, reason} ->
          {:error, classify_error(reason)}
      end
    catch
      :exit, reason ->
        {:error, {:transient, {:exit, reason}}}
    end
  end

  @doc """
  Uploads a local file to S3, raising on error.

  Returns the S3 key on success.
  """
  def upload_file!(local_path, s3_key) do
    case upload_file(local_path, s3_key) do
      :ok -> s3_key
      {:error, reason} -> raise "Failed to upload file: #{inspect(reason)}"
    end
  end

  @doc """
  Deletes an object from S3 idempotently (HTTP 404 is treated as `:ok`).

  Returns `:ok` on success or `{:error, error_reason}` on failure.
  """
  def delete_object(s3_key) do
    key = full_key(s3_key)

    case ExAws.S3.delete_object(bucket(), key) |> ExAws.request() do
      {:ok, %{status_code: status}} when status in 200..299 ->
        :ok

      {:error, {:http_error, 404, _}} ->
        :ok

      {:ok, %{status_code: status} = resp} ->
        {:error, classify_error({:http_error, status, resp})}

      {:error, reason} ->
        {:error, classify_error(reason)}
    end
  end

  @doc """
  Checks if an object exists in S3.

  Returns `{:ok, true}`, `{:ok, false}`, or `{:error, error_reason}`.
  """
  def object_exists(s3_key) do
    key = full_key(s3_key)

    case ExAws.S3.head_object(bucket(), key) |> ExAws.request() do
      {:ok, %{status_code: status}} when status in 200..299 ->
        {:ok, true}

      {:error, {:http_error, 404, _}} ->
        {:ok, false}

      {:ok, %{status_code: status} = resp} ->
        {:error, classify_error({:http_error, status, resp})}

      {:error, reason} ->
        {:error, classify_error(reason)}
    end
  end

  @doc """
  Generates a presigned GET URL for an S3 object.

  Returns the URL string or `nil` if `s3_key` is `nil`.
  """
  def presigned_get_url(s3_key, expires_in \\ 3600)
  def presigned_get_url(nil, _expires_in), do: nil

  def presigned_get_url(s3_key, expires_in) do
    config = ExAws.Config.new(:s3)
    key = full_key(s3_key)
    {:ok, url} = ExAws.S3.presigned_url(config, :get, bucket(), key, expires_in: expires_in)
    url
  end

  @doc """
  Generates a presigned PUT URL for an S3 object.

  Returns the URL string.
  """
  def presigned_put_url(s3_key, expires_in \\ 3600, query_params \\ []) do
    config = ExAws.Config.new(:s3)
    key = full_key(s3_key)

    {:ok, url} =
      ExAws.S3.presigned_url(config, :put, bucket(), key,
        expires_in: expires_in,
        query_params: query_params
      )

    url
  end

  @doc """
  Classifies an ExAws error into `:not_found`, `{:transient, reason}`, or `{:permanent, reason}`.
  """
  def classify_error({:http_error, 404, _}), do: :not_found

  def classify_error({:http_error, status, _} = err)
      when status in [408, 429] or status >= 500 do
    {:transient, err}
  end

  def classify_error({:http_error, status, _} = err) when status in 400..499 do
    {:permanent, err}
  end

  def classify_error(%ExAws.Error{message: message} = err) when is_binary(message) do
    if String.contains?(message, "http_error, 404") or
         String.contains?(message, "status_code: 404") do
      :not_found
    else
      {:transient, err}
    end
  end

  def classify_error(reason), do: {:transient, reason}

  @doc """
  Returns the configured S3 bucket name.
  """
  def bucket, do: Application.get_env(:sonnet, :ingest_bucket)

  @doc """
  Returns the configured S3 prefix (defaults to empty string).
  """
  def prefix, do: Application.get_env(:sonnet, :ingest_prefix) || ""

  @doc """
  Returns the full S3 key by joining the prefix with the given key.
  """
  def full_key(s3_key), do: Path.join(prefix(), s3_key)
end
