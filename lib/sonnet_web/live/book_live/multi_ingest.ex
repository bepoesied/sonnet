defmodule SonnetWeb.BookLive.MultiIngest do
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
          <h1 class="text-4xl font-bold tracking-tight">Upload Multi-File Book</h1>
        </div>

        <div class="alert alert-info">
          <.icon name="hero-information-circle" class="size-6 shrink-0" />
          <div>
            <h3 class="font-bold">Multi-File Upload</h3>
            <div class="text-xs">
              Each MP3 file will become its own chapter in the book. Files will be ordered by name.
            </div>
          </div>
        </div>

        <.form
          for={@form}
          id="multi-upload-form"
          phx-change="validate"
          phx-submit="save"
          class="flex flex-col gap-4"
        >
          <.input field={@form[:title]} type="text" label="Title" required />
          <.input field={@form[:author]} type="text" label="Author" />
          <.input field={@form[:narrator]} type="text" label="Narrator" />
          <.input field={@form[:description]} type="textarea" label="Description" rows="3" />

          <label for={@uploads.multi_book.ref} phx-drop-target={@uploads.multi_book.ref}>
            <div class="label">
              <span class="label-text">Audio Files (.mp3)</span>
              <span class="label-text-alt">Each file becomes a chapter</span>
            </div>
            <.live_file_input upload={@uploads.multi_book} class="file-input" />
          </label>

          <div
            :for={entry <- @uploads.multi_book.entries}
            class="flex items-center gap-2"
          >
            <span class="text-sm">{entry.client_name}</span>
            <progress class="progress grow" value={entry.progress} max="100">
              {entry.progress}%
            </progress>
          </div>

          <.button type="submit" disabled={!at_least_onefile_selected?(@uploads.multi_book)}>
            Upload
          </.button>
        </.form>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> allow_upload(:multi_book,
        accept: ~w(.mp3),
        max_entries: 100,
        max_file_size: 5_000_000_000,
        external: &presign_upload/2
      )
      |> assign(
        :form,
        to_form(%{"title" => nil, "author" => nil, "narrator" => nil, "description" => nil},
          as: :multi_book
        )
      )

    {:ok, socket}
  end

  @impl true
  def handle_event("validate", %{"multi_book" => book_params}, socket) do
    {:noreply, assign(socket, :form, to_form(book_params, as: :multi_book))}
  end

  @impl true
  def handle_event("save", %{"multi_book" => book_params}, socket) do
    uploaded_files =
      consume_uploaded_entries(socket, :multi_book, fn meta, entry ->
        {:ok, %{key: meta.key, client_name: entry.client_name}}
      end)

    case uploaded_files do
      [] ->
        {:noreply, put_flash(socket, :error, "Please select at least one file")}

      files ->
        files_with_durations =
          Enum.map(files, fn file ->
            duration = probe_audio_duration(file.key)
            Map.put(file, :duration_ms, duration)
          end)

        sorted_files = Enum.sort_by(files_with_durations, & &1.client_name)
        s3_keys = Enum.map(sorted_files, & &1.key)
        original_filenames = Enum.map(sorted_files, & &1.client_name)
        durations = Enum.map(sorted_files, & &1.duration_ms)

        media_assets = Enum.map(s3_keys, &Sonnet.Library.create_media_asset!/1)

        case Sonnet.Library.ingest_multi_file!(
               s3_keys,
               original_filenames,
               media_assets,
               durations,
               book_params
             ) do
          {:ok, _} ->
            Sonnet.Library.broadcast_books_updated()

            {:noreply,
             socket
             |> put_flash(:info, "Successfully uploaded #{length(files)} files")
             |> redirect(to: ~p"/library")}

          {:error, _name, reason, _changes} ->
            {:noreply, put_flash(socket, :error, "Error creating book: #{inspect(reason)}")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Error creating book: #{inspect(reason)}")}
        end
    end
  end

  defp probe_audio_duration(s3_key) do
    key = full_s3_key(s3_key)
    path = Briefly.create!(type: :path)

    case ExAws.S3.download_file(bucket(), key, path) |> ExAws.request() do
      {:ok, _} ->
        case System.cmd("ffprobe", [
               "-v",
               "quiet",
               "-print_format",
               "json",
               "-show_format",
               path
             ]) do
          {output, 0} ->
            case Jason.decode(output) do
              {:ok, %{"format" => %{"duration" => duration}}} ->
                floor(String.to_float(duration) * 1000)

              _ ->
                0
            end

          _ ->
            0
        end

      _ ->
        0
    end
  end

  defp full_s3_key(s3_key) do
    prefix = Application.get_env(:sonnet, :ingest_prefix) || ""
    Path.join(prefix, s3_key)
  end

  defp bucket do
    Application.get_env(:sonnet, :ingest_bucket)
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
