defmodule SonnetWeb.LibraryLive do
  use SonnetWeb, :live_view
  alias Sonnet.Library

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Library.subscribe()
    user_id = socket.assigns.current_scope.user.id

    socket =
      socket
      |> stream(:books, Library.list_books(user_id))

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    book = Library.get_book!(id)

    socket
    |> assign(:page_title, "Edit Book")
    |> assign(:editing_book, book)
    |> assign(:edit_form, to_form(Sonnet.Library.Book.changeset(book, %{})))
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
  def handle_event("mark_complete", %{"id" => id}, socket) do
    book_id = String.to_integer(id)
    user_id = socket.assigns.current_scope.user.id
    book = Library.get_book!(book_id)

    chapter_id =
      case Library.get_listen_progress(user_id, book_id) do
        nil -> List.first(book.chapters).id
        progress -> progress.chapter_id
      end

    Library.mark_book_complete(user_id, book_id, chapter_id)

    updated_book = Library.get_book_with_status!(book_id, user_id)

    {:noreply, stream_insert(socket, :books, updated_book)}
  end

  @impl true
  def handle_event("mark_incomplete", %{"id" => id}, socket) do
    book_id = String.to_integer(id)
    user_id = socket.assigns.current_scope.user.id

    Library.mark_book_incomplete(user_id, book_id)
    updated_book = Library.get_book_with_status!(book_id, user_id)

    {:noreply, stream_insert(socket, :books, updated_book)}
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
    {:noreply, stream(socket, :books, Library.list_books(user_id), reset: true)}
  end
end
