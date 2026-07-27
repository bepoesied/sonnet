defmodule SonnetWeb.LibraryLive do
  use SonnetWeb, :live_view
  alias Sonnet.Library

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Library.subscribe()
    user_id = socket.assigns.current_scope.user.id

    socket =
      socket
      |> assign(:search, "")
      |> stream(:books, Library.list_books(user_id))

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    with {:ok, book_id} <- parse_id(id),
         book when not is_nil(book) <- Library.get_book(book_id) do
      socket
      |> allow_upload(:cover,
        accept: ~w(.jpg .jpeg .png .webp .gif .bmp),
        max_entries: 1,
        max_file_size: 10_000_000,
        auto_upload: true
      )
      |> assign(:page_title, "Edit Book")
      |> assign(:editing_book, book)
      |> assign(:edit_form, to_form(Sonnet.Library.Book.changeset(book, %{})))
    else
      _ ->
        socket
        |> put_flash(:error, "Book not found")
        |> push_patch(to: ~p"/library")
        |> apply_action(:index, %{})
    end
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Library")
    |> assign(:editing_book, nil)
    |> assign(:edit_form, nil)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="container mx-auto pb-4">
        <div class="flex items-center gap-6 px-2 py-12">
          <h1 class="text-4xl font-bold tracking-tight">Library</h1>
          <.link
            navigate={~p"/ingest"}
            class="btn btn-primary btn-circle shadow-md hover:scale-110 transition-transform"
            title="Upload Book"
          >
            <.icon name="hero-plus" class="size-6" />
          </.link>
        </div>

        <form phx-change="search" class="px-2 mb-6">
          <input
            type="text"
            placeholder="Search by title or author..."
            value={@search}
            phx-debounce="300"
            name="term"
            class="input input-bordered w-full max-w-md"
          />
        </form>

        <div
          id="books"
          phx-update="stream"
          class="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 xl:grid-cols-6 gap-4 sm:gap-8 px-2"
        >
          <.book_card :for={{id, book} <- @streams.books} id={id} book={book} />
        </div>
      </div>

      <.modal
        :if={@live_action == :edit}
        id="edit-book-modal"
        show
        on_cancel={JS.patch(~p"/library")}
      >
        <:title>Edit Book</:title>
        <.form
          for={@edit_form}
          id="edit-book-form"
          phx-change="validate_edit"
          phx-submit="save_edit"
        >
          <div class="space-y-4">
            <.input field={@edit_form[:title]} type="text" label="Title" required />
            <.input field={@edit_form[:author]} type="text" label="Author" />
            <.input field={@edit_form[:narrator]} type="text" label="Narrator" />
            <.input field={@edit_form[:description]} type="textarea" label="Description" rows="3" />

            <div>
              <label class="label">
                <span class="label-text">Cover Image</span>
              </label>
              <label for={@uploads.cover.ref} phx-drop-target={@uploads.cover.ref}>
                <.live_file_input
                  upload={@uploads.cover}
                  class="file-input file-input-bordered w-full"
                />
              </label>

              <div
                :for={entry <- @uploads.cover.entries}
                :if={entry.progress > 0}
                class="mt-2"
              >
                <progress class="progress progress-primary w-full" value={entry.progress} max="100">
                  {entry.progress}%
                </progress>
              </div>
            </div>
          </div>

          <div class="modal-action">
            <.button type="submit" phx-disable-with="Saving...">Save Changes</.button>
          </div>
        </.form>
      </.modal>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("search", %{"term" => term}, socket) do
    user_id = socket.assigns.current_scope.user.id
    term = String.trim(term)

    books =
      if term == "",
        do: Library.list_books(user_id),
        else: Library.search_books(user_id, term)

    socket =
      socket
      |> assign(:search, term)
      |> stream(:books, books, reset: true)

    {:noreply, socket}
  end

  @impl true
  def handle_event("mark_complete", %{"id" => id}, socket) do
    user_id = socket.assigns.current_scope.user.id

    with {:ok, book_id} <- parse_id(id),
         book when not is_nil(book) <- Library.get_book(book_id),
         {:ok, chapter_id} <- progress_or_first_chapter_id(user_id, book),
         {:ok, _progress} <- Library.mark_book_complete(user_id, book_id, chapter_id),
         updated_book when not is_nil(updated_book) <-
           Library.get_book_with_status(book_id, user_id) do
      {:noreply, stream_insert(socket, :books, updated_book)}
    else
      {:error, :no_chapters} -> {:noreply, put_flash(socket, :error, "Book has no chapters")}
      _ -> {:noreply, put_flash(socket, :error, "Could not mark book complete")}
    end
  end

  @impl true
  def handle_event("mark_incomplete", %{"id" => id}, socket) do
    user_id = socket.assigns.current_scope.user.id

    with {:ok, book_id} <- parse_id(id),
         book when not is_nil(book) <- Library.get_book(book_id),
         {:ok, _progress} <- Library.mark_book_incomplete(user_id, book.id),
         updated_book when not is_nil(updated_book) <-
           Library.get_book_with_status(book_id, user_id) do
      {:noreply, stream_insert(socket, :books, updated_book)}
    else
      _ -> {:noreply, put_flash(socket, :error, "Could not mark book incomplete")}
    end
  end

  @impl true
  def handle_event("delete_book", %{"id" => id}, socket) do
    with {:ok, book_id} <- parse_id(id),
         {:ok, _book} <- Library.delete_book(book_id) do
      socket =
        socket
        |> put_flash(:info, "Book deleted successfully")
        |> stream_delete(:books, %{id: book_id})

      {:noreply, socket}
    else
      _ -> {:noreply, put_flash(socket, :error, "Failed to delete book")}
    end
  end

  @impl true
  def handle_event("validate_edit", %{"book" => book_params}, socket) do
    changeset =
      socket.assigns.editing_book
      |> Sonnet.Library.Book.changeset(book_params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :edit_form, to_form(changeset))}
  end

  @impl true
  def handle_event("save_edit", %{"book" => book_params}, socket) do
    book = socket.assigns.editing_book

    cover_s3_key =
      consume_uploaded_entries(socket, :cover, fn %{path: path}, entry ->
        cover_s3_key = Sonnet.Media.process_cover_upload(path, entry.client_name)
        {:ok, cover_s3_key}
      end)
      |> case do
        [key] -> key
        [] -> nil
      end

    book_params =
      if cover_s3_key do
        Map.put(book_params, "cover_s3_key", cover_s3_key)
      else
        book_params
      end

    case Library.update_book(book.id, book_params) do
      {:ok, _updated_book} ->
        socket =
          socket
          |> put_flash(:info, "Book updated successfully")
          |> push_patch(to: ~p"/library")

        {:noreply, socket}

      {:error, changeset} ->
        {:noreply, assign(socket, :edit_form, to_form(changeset))}
    end
  end

  @impl true
  def handle_info(:books_updated, socket) do
    user_id = socket.assigns.current_scope.user.id

    books =
      if socket.assigns.search == "",
        do: Library.list_books(user_id),
        else: Library.search_books(user_id, socket.assigns.search)

    {:noreply, stream(socket, :books, books, reset: true)}
  end

  defp progress_or_first_chapter_id(user_id, book) do
    case Library.get_listen_progress(user_id, book.id) do
      nil -> first_chapter_id(book)
      progress -> {:ok, progress.chapter_id}
    end
  end

  defp first_chapter_id(book) do
    case List.first(book.chapters) do
      nil -> {:error, :no_chapters}
      chapter -> {:ok, chapter.id}
    end
  end

  defp parse_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> {:ok, integer}
      _ -> :error
    end
  end

  defp parse_id(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp parse_id(_value), do: :error
end
