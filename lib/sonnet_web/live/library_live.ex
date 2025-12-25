defmodule SonnetWeb.LibraryLive do
  use SonnetWeb, :live_view
  alias Sonnet.Library

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Library.subscribe()
    user_id = socket.assigns.current_scope.user.id

    {:ok, stream(socket, :books, Library.list_books(user_id))}
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
  def handle_info(:books_updated, socket) do
    user_id = socket.assigns.current_scope.user.id
    {:noreply, stream(socket, :books, Library.list_books(user_id), reset: true)}
  end
end
