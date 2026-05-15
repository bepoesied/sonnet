defmodule Sonnet.StorageTest do
  use ExUnit.Case, async: true

  alias Sonnet.Storage

  setup do
    original_prefix = Application.get_env(:sonnet, :ingest_prefix)
    original_bucket = Application.get_env(:sonnet, :ingest_bucket)
    original_access_key_id = Application.get_env(:ex_aws, :access_key_id)
    original_secret_access_key = Application.get_env(:ex_aws, :secret_access_key)
    original_ex_aws_s3 = Application.get_env(:ex_aws, :s3)

    Application.put_env(:sonnet, :ingest_bucket, "sonnet-test")

    Application.put_env(:ex_aws, :access_key_id, "test-access-key")
    Application.put_env(:ex_aws, :secret_access_key, "test-secret-key")

    Application.put_env(:ex_aws, :s3,
      host: "localhost",
      scheme: "http://",
      port: 3900,
      region: "us-east-1"
    )

    on_exit(fn ->
      Application.put_env(:sonnet, :ingest_prefix, original_prefix)
      Application.put_env(:sonnet, :ingest_bucket, original_bucket)

      restore_env(:ex_aws, :access_key_id, original_access_key_id)
      restore_env(:ex_aws, :secret_access_key, original_secret_access_key)
      restore_env(:ex_aws, :s3, original_ex_aws_s3)
    end)

    :ok
  end

  test "full_key/1 returns the relative key when prefix is empty" do
    Application.put_env(:sonnet, :ingest_prefix, "")

    assert Storage.full_key("books/chapter-1.mp3") == "books/chapter-1.mp3"
  end

  test "full_key/1 prepends the configured prefix" do
    Application.put_env(:sonnet, :ingest_prefix, "uploads")

    assert Storage.full_key("books/chapter-1.mp3") == "uploads/books/chapter-1.mp3"
  end

  test "presigned URLs apply the configured prefix internally" do
    Application.put_env(:sonnet, :ingest_prefix, "library")

    get_url = Storage.presigned_get_url("books/chapter-1.mp3")
    put_url = Storage.presigned_put_url("incoming/upload.m4b")

    assert URI.parse(get_url).path == "/sonnet-test/library/books/chapter-1.mp3"
    assert URI.parse(put_url).path == "/sonnet-test/library/incoming/upload.m4b"
  end

  test "presigned_get_url/2 returns nil for nil keys" do
    assert Storage.presigned_get_url(nil) == nil
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
