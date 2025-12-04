defmodule SonnetWeb.BookLive.Ingest do
  use SonnetWeb, :live_view

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="text-center flex flex-col gap-6">
        <.header>
          Upload Book
        </.header>
        <form id="upload-form" phx-change="validate" phx-submit="save" class="flex flex-col gap-2">
          <label for={@uploads.book.ref} phx-drop-target={@uploads.book.ref}>
            <.live_file_input upload={@uploads.book} class="file-input" />
          </label>
          <.button type="submit" disabled={!at_least_onefile_selected?(@uploads.book)}>
            Upload
          </.button>
        </form>
        <div
          :for={entry <- @uploads.book.entries}
          :if={entry.progress > 0}
          class="flex items-center gap-2"
        >
          <progress class="progress grow" value={entry.progress} max="100">
            {entry.progress}%
          </progress>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> allow_upload(:book,
        accept: ~w(.m4b .m4a),
        max_entries: 1,
        max_file_size: 5_000_000_000,
        external: &presign_upload/2
      )

    {:ok, socket}
  end

  @impl true
  def handle_event("validate", _params, socket) do
    socket =
      socket

    {:noreply, socket}
  end

  @impl true
  def handle_event("save", _params, socket) do
    [uploaded_file | _] =
      consume_uploaded_entries(socket, :book, fn meta, entry ->
        key = meta.key
        client_name = entry.client_name
        {:ok, %{key: key, client_name: client_name}}
      end)

    {:ok, _} =
      %{s3_key: uploaded_file.key}
      |> Sonnet.Workers.Ingester.new()
      |> Oban.insert()

    socket =
      socket
      |> put_flash(:info, "Successfully uploaded #{uploaded_file.client_name}")

    {:noreply, socket}
  end

  defp presign_upload(entry, socket) do
    config = ExAws.Config.new(:s3)
    bucket = Application.get_env(:sonnet, :ingest_bucket)
    prefix = Application.get_env(:sonnet, :ingest_prefix)
    key = "#{prefix}/#{Ecto.UUID.generate()}"

    {:ok, url} =
      ExAws.S3.presigned_url(config, :put, bucket, key,
        expires_in: 3600,
        query_params: [{"Content-Type", entry.client_type}]
      )

    {:ok, %{uploader: "S3", key: key, url: url}, socket}
  end

  defp at_least_onefile_selected?(upload) do
    upload.entries |> Enum.any?()
  end
end
