defmodule SonnetWeb.BookLive.Ingest do
  use SonnetWeb, :live_view

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="flex flex-col gap-6">
        <div class="flex items-center gap-6 py-12">
          <.link
            navigate={~p"/library"}
            class="btn btn-primary btn-circle shadow-md hover:scale-110 transition-transform"
            title="Back to Library"
          >
            <.icon name="hero-arrow-left" class="size-6" />
          </.link>
          <h1 class="text-4xl font-bold tracking-tight">Upload Book</h1>
        </div>

        <div class="collapse collapse-arrow bg-base-200">
          <input type="checkbox" checked />
          <div class="collapse-title text-xl font-medium">
            Single File Upload (.m4b, .m4a)
          </div>
          <div class="collapse-content">
            <.form
              for={@form}
              id="upload-form"
              phx-change="validate"
              phx-submit="save"
              class="flex flex-col gap-4"
            >
              <.input field={@form[:title]} type="text" label="Title (optional)" />
              <.input field={@form[:author]} type="text" label="Author (optional)" />
              <.input field={@form[:narrator]} type="text" label="Narrator (optional)" />
              <.input
                field={@form[:description]}
                type="textarea"
                label="Description (optional)"
                rows="3"
              />

              <label for={@uploads.book.ref} phx-drop-target={@uploads.book.ref}>
                <.live_file_input upload={@uploads.book} class="file-input" />
              </label>

              <div
                :for={entry <- @uploads.book.entries}
                :if={entry.progress > 0}
                class="flex items-center gap-2"
              >
                <progress class="progress grow" value={entry.progress} max="100">
                  {entry.progress}%
                </progress>
              </div>

              <.button type="submit" disabled={!at_least_onefile_selected?(@uploads.book)}>
                Upload
              </.button>
            </.form>
          </div>
        </div>

        <div class="divider">OR</div>

        <.link
          navigate={~p"/multi-ingest"}
          class="btn btn-outline btn-lg"
        >
          <.icon name="hero-arrow-up-tray" class="size-6" /> Upload Multi-File Book (.mp3 files)
        </.link>

        <div class="divider">OR</div>

        <div class="collapse collapse-arrow bg-base-200">
          <input type="checkbox" />
          <div class="collapse-title text-xl font-medium">
            Advanced Import
          </div>
          <div class="collapse-content">
            <.form
              for={@bulk_form}
              id="bulk-upload-form"
              phx-submit="bulk_save"
              class="flex flex-col gap-2"
            >
              <.input
                field={@bulk_form[:keys]}
                type="textarea"
                label="S3 Keys (newline separated)"
                placeholder="incoming/file1.m4b\nincoming/file2.m4b"
                rows="10"
              />
              <.button type="submit">
                Bulk Import
              </.button>
            </.form>
          </div>
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
      |> assign(
        :form,
        to_form(%{"title" => nil, "author" => nil, "narrator" => nil, "description" => nil},
          as: :book
        )
      )
      |> assign(:bulk_form, to_form(%{"keys" => ""}, as: :bulk))

    {:ok, socket}
  end

  @impl true
  def handle_event("validate", %{"book" => book_params}, socket) do
    {:noreply, assign(socket, :form, to_form(book_params, as: :book))}
  end

  @impl true
  def handle_event("bulk_save", %{"bulk" => %{"keys" => keys_string}}, socket) do
    keys =
      keys_string
      |> String.split(["\n", "\r", "\r\n"], trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    for key <- keys do
      %{s3_key: key, original_filename: Path.basename(key)}
      |> Sonnet.Workers.Ingester.new()
      |> Oban.insert()
    end

    socket =
      socket
      |> put_flash(:info, "Started importing #{length(keys)} files")
      |> assign(:bulk_form, to_form(%{"keys" => ""}, as: :bulk))

    {:noreply, socket}
  end

  @impl true
  def handle_event("save", %{"book" => book_params}, socket) do
    [uploaded_file] =
      consume_uploaded_entries(socket, :book, fn meta, entry ->
        key = meta.key
        client_name = entry.client_name
        {:ok, %{key: key, client_name: client_name}}
      end)

    {:ok, _} =
      %{
        s3_key: uploaded_file.key,
        original_filename: uploaded_file.client_name,
        book_metadata: book_params
      }
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
    key = Path.join(prefix, Ecto.UUID.generate())

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
