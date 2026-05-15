defmodule Sonnet.Storage do
  @moduledoc """
  Storage context for managing S3 operations.
  """

  require Logger

  @doc """
  Downloads a file from S3 to the specified local path.

  Returns `{:ok, path}` on success, `{:error, :not_found}` if the object doesn't exist,
  or `{:error, {:transient, reason}}` for other errors.
  """
  def download_file(s3_key, local_path) do
    key = full_key(s3_key)

    case ExAws.S3.download_file(bucket(), key, local_path) |> ExAws.request() do
      {:ok, _} ->
        {:ok, local_path}

      {:error, {:http_error, 404, _}} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, {:transient, reason}}
    end
  end

  @doc """
  Uploads a local file to S3.

  Returns `:ok` on success or `{:error, reason}` on failure.
  """
  def upload_file(local_path, s3_key) do
    key = full_key(s3_key)

    result =
      local_path
      |> ExAws.S3.Upload.stream_file()
      |> ExAws.S3.upload(bucket(), key)
      |> ExAws.request()

    case result do
      {:ok, %{status_code: status}} when status in 200..299 -> :ok
      {:error, reason} -> {:error, reason}
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
  Deletes an object from S3.

  Returns `:ok` on success or `{:error, reason}` on failure.
  """
  def delete_object(s3_key) do
    key = full_key(s3_key)
    result = ExAws.S3.delete_object(bucket(), key) |> ExAws.request()

    case result do
      {:ok, %{status_code: status}} when status in 200..299 -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Checks if an object exists in S3.

  Returns `true` if the object exists, `false` if it doesn't.
  Logs warnings for errors other than 404.
  """
  def object_exists?(s3_key) do
    key = full_key(s3_key)
    result = ExAws.S3.head_object(bucket(), key) |> ExAws.request()

    case result do
      {:ok, %{status_code: status}} when status in 200..299 ->
        true

      {:error, {:http_error, 404, _}} ->
        false

      {:error, reason} ->
        Logger.warning("Error checking S3 object existence (#{key}): #{inspect(reason)}")
        false
    end
  end

  @doc """
  Generates a presigned GET URL for an S3 object.

  Returns the URL string or `nil` if s3_key is nil.
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
