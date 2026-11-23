defmodule Sonnet.Test.S3Stub do
  @moduledoc """
  `Req.Test`-backed S3 HTTP stub for testing `Sonnet.Storage` and ingestion workers
  through the real `ExAws.S3` + `ExAws.Request.Req` stack with full `async: true` isolation.
  """

  import Plug.Conn

  def start! do
    {:ok, agent} =
      Agent.start_link(fn ->
        %{
          objects: %{},
          uploads: %{},
          next_failures: []
        }
      end)

    Req.Test.stub(Sonnet.Storage, fn conn ->
      handle_request(conn, agent)
    end)

    agent
  end

  def put_object(agent, s3_key, binary) when is_binary(s3_key) and is_binary(binary) do
    Agent.update(agent, fn state -> put_in(state, [:objects, s3_key], binary) end)
  end

  def put_file(agent, s3_key, local_path) do
    put_object(agent, s3_key, File.read!(local_path))
  end

  def has_object?(agent, s3_key) do
    Agent.get(agent, fn state -> Map.has_key?(state.objects, s3_key) end)
  end

  def list_keys(agent) do
    Agent.get(agent, fn state -> state.objects |> Map.keys() |> Enum.sort() end)
  end

  @doc """
  Injects a single failure for the next matching S3 HTTP operation.

  - `op`: `:head | :download | :upload | :delete`
  - `match`: `:any`, an exact `s3_key` string, or a 1-arity predicate function
  - `failure`: an HTTP status integer (e.g. `503`, `403`) or a transport error atom (e.g. `:timeout`, `:econnrefused`)
  """
  def fail_next(agent, op, match \\ :any, failure) do
    Agent.update(agent, fn state ->
      %{state | next_failures: state.next_failures ++ [{op, match, failure}]}
    end)
  end

  defp handle_request(conn, agent) do
    conn = fetch_query_params(conn)
    [bucket | key_parts] = conn.path_info
    s3_key = Enum.join(key_parts, "/")

    case {conn.method, conn.query_params} do
      {"HEAD", _} ->
        with_failure_injection(conn, agent, :head, s3_key, fn conn ->
          handle_head(conn, agent, s3_key)
        end)

      {"GET", _} ->
        with_failure_injection(conn, agent, :download, s3_key, fn conn ->
          handle_get(conn, agent, s3_key)
        end)

      {"POST", %{"uploads" => _}} ->
        with_failure_injection(conn, agent, :upload, s3_key, fn conn ->
          handle_init_multipart(conn, agent, bucket, s3_key)
        end)

      {"PUT", %{"uploadId" => upload_id, "partNumber" => part_number}} ->
        with_failure_injection(conn, agent, :upload, s3_key, fn conn ->
          handle_upload_part(conn, agent, upload_id, String.to_integer(part_number))
        end)

      {"POST", %{"uploadId" => upload_id}} ->
        with_failure_injection(conn, agent, :upload, s3_key, fn conn ->
          handle_complete_multipart(conn, agent, bucket, s3_key, upload_id)
        end)

      {"DELETE", _} ->
        with_failure_injection(conn, agent, :delete, s3_key, fn conn ->
          handle_delete(conn, agent, s3_key)
        end)
    end
  end

  defp handle_head(conn, agent, s3_key) do
    case get_object(agent, s3_key) do
      nil ->
        send_resp(conn, 404, "")

      bytes ->
        conn
        |> put_resp_header("content-length", Integer.to_string(byte_size(bytes)))
        |> send_resp(200, "")
    end
  end

  defp handle_get(conn, agent, s3_key) do
    case get_object(agent, s3_key) do
      nil ->
        send_resp(conn, 404, "")

      bytes ->
        case get_req_header(conn, "range") do
          ["bytes=" <> range] ->
            [start_s, end_s] = String.split(range, "-")
            start_byte = String.to_integer(start_s)
            end_byte = min(String.to_integer(end_s), byte_size(bytes) - 1)
            chunk = binary_part(bytes, start_byte, end_byte - start_byte + 1)
            send_resp(conn, 206, chunk)

          _ ->
            send_resp(conn, 200, bytes)
        end
    end
  end

  defp handle_init_multipart(conn, agent, bucket, s3_key) do
    upload_id = Ecto.UUID.generate()

    Agent.update(agent, fn state ->
      put_in(state, [:uploads, upload_id], %{key: s3_key, parts: %{}})
    end)

    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <InitiateMultipartUploadResult>
      <Bucket>#{bucket}</Bucket>
      <Key>#{s3_key}</Key>
      <UploadId>#{upload_id}</UploadId>
    </InitiateMultipartUploadResult>
    """

    conn
    |> put_resp_content_type("application/xml")
    |> send_resp(200, xml)
  end

  defp handle_upload_part(conn, agent, upload_id, part_number) do
    {:ok, body, conn} = read_full_body(conn, "")

    Agent.update(agent, fn state ->
      put_in(state, [:uploads, upload_id, :parts, part_number], body)
    end)

    conn
    |> put_resp_header("etag", ~s("part-#{part_number}"))
    |> send_resp(200, "")
  end

  defp handle_complete_multipart(conn, agent, bucket, s3_key, upload_id) do
    {:ok, _body, conn} = read_full_body(conn, "")

    Agent.update(agent, fn state ->
      {upload, uploads} = Map.pop!(state.uploads, upload_id)

      bytes =
        upload.parts
        |> Enum.sort_by(fn {part_num, _} -> part_num end)
        |> Enum.map_join(fn {_part_num, chunk} -> chunk end)

      state
      |> Map.put(:uploads, uploads)
      |> put_in([:objects, s3_key], bytes)
    end)

    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <CompleteMultipartUploadResult>
      <Location>http://localhost:3900/#{bucket}/#{s3_key}</Location>
      <Bucket>#{bucket}</Bucket>
      <Key>#{s3_key}</Key>
      <ETag>"complete"</ETag>
    </CompleteMultipartUploadResult>
    """

    conn
    |> put_resp_content_type("application/xml")
    |> send_resp(200, xml)
  end

  defp handle_delete(conn, agent, s3_key) do
    existed? =
      Agent.get_and_update(agent, fn state ->
        {Map.has_key?(state.objects, s3_key),
         %{state | objects: Map.delete(state.objects, s3_key)}}
      end)

    send_resp(conn, if(existed?, do: 204, else: 404), "")
  end

  defp get_object(agent, s3_key) do
    Agent.get(agent, fn state -> Map.get(state.objects, s3_key) end)
  end

  defp read_full_body(conn, acc) do
    case read_body(conn) do
      {:ok, chunk, conn} -> {:ok, acc <> chunk, conn}
      {:more, chunk, conn} -> read_full_body(conn, acc <> chunk)
    end
  end

  defp with_failure_injection(conn, agent, op, s3_key, fun) do
    case pop_failure(agent, op, s3_key) do
      :ok ->
        fun.(conn)

      {:fail, status} when is_integer(status) ->
        send_resp(conn, status, "")

      {:fail, reason} when is_atom(reason) ->
        Req.Test.transport_error(conn, reason)
    end
  end

  defp pop_failure(agent, op, s3_key) do
    Agent.get_and_update(agent, fn state ->
      case take_matching(state.next_failures, op, s3_key, []) do
        {:found, failure, remaining} ->
          {{:fail, failure}, %{state | next_failures: remaining}}

        :none ->
          {:ok, state}
      end
    end)
  end

  defp take_matching([], _op, _s3_key, _acc), do: :none

  defp take_matching([{op, match, failure} | rest], op, s3_key, acc) do
    matched? =
      cond do
        match == :any -> true
        is_function(match, 1) -> match.(s3_key)
        true -> match == s3_key
      end

    if matched? do
      {:found, failure, Enum.reverse(acc) ++ rest}
    else
      take_matching(rest, op, s3_key, [{op, match, failure} | acc])
    end
  end

  defp take_matching([entry | rest], op, s3_key, acc) do
    take_matching(rest, op, s3_key, [entry | acc])
  end
end
