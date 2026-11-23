defmodule Sonnet.StorageTest do
  use ExUnit.Case, async: false

  alias Sonnet.Storage
  alias Sonnet.Test.S3Stub

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

  describe "classify_error/1" do
    test "classifies 404 as :not_found" do
      assert Storage.classify_error({:http_error, 404, %{}}) == :not_found

      assert Storage.classify_error(%ExAws.Error{
               message: "ExAws Request Error!\n{:error, {:http_error, 404, %{}}}"
             }) == :not_found
    end

    test "classifies 408, 429, 5xx, and transport errors as transient" do
      assert {:transient, _} = Storage.classify_error({:http_error, 408, %{}})
      assert {:transient, _} = Storage.classify_error({:http_error, 429, %{}})
      assert {:transient, _} = Storage.classify_error({:http_error, 503, %{}})
      assert {:transient, _} = Storage.classify_error(%{reason: :timeout})
    end

    test "classifies non-retryable 4xx errors as permanent" do
      assert {:permanent, _} = Storage.classify_error({:http_error, 403, %{}})
      assert {:permanent, _} = Storage.classify_error({:http_error, 400, %{}})
    end
  end

  describe "S3 HTTP operations via ExAws.S3 + Req.Test" do
    test "uploads, checks existence, downloads, and idempotently deletes objects" do
      Application.put_env(:sonnet, :ingest_prefix, "")
      s3 = S3Stub.start!()

      local_src = Briefly.create!(type: :path)
      local_dst = Briefly.create!(type: :path)
      File.write!(local_src, "hello sonnet audio")

      assert {:ok, false} = Storage.object_exists("books/test.bin")
      assert {:error, :not_found} = Storage.download_file("books/test.bin", local_dst)

      assert :ok = Storage.upload_file(local_src, "books/test.bin")
      assert {:ok, true} = Storage.object_exists("books/test.bin")
      assert {:ok, ^local_dst} = Storage.download_file("books/test.bin", local_dst)
      assert File.read!(local_dst) == "hello sonnet audio"

      assert :ok = Storage.delete_object("books/test.bin")
      assert {:ok, false} = Storage.object_exists("books/test.bin")
      # Deleting an already-missing object (404) is idempotent.
      assert :ok = Storage.delete_object("books/test.bin")

      # Transient 503 on HEAD returns {:error, {:transient, _}} instead of false.
      S3Stub.fail_next(s3, :head, "books/test.bin", 503)

      assert {:error, {:transient, {:http_error, 503, _}}} =
               Storage.object_exists("books/test.bin")
    end
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
