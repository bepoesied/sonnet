defmodule SonnetWeb.LibraryLive do
  use SonnetWeb, :live_view
  alias Sonnet.Library

  @impl true
  def mount(_params, _session, socket) do
    books = Library.list_books()
    {:ok, assign(socket, books: books, playing_book: nil, audio_url: nil, start_at: 0)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="p-6">
        <.header>
          Library
        </.header>

        <div class="grid grid-cols-2 md:grid-cols-4 lg:grid-cols-6 gap-6 mt-8">
          <div
            :for={book <- @books}
            id={"book-#{book.id}"}
            class="cursor-pointer group"
            phx-click="play"
            phx-value-id={book.id}
          >
            <div class="aspect-[2/3] bg-zinc-800 rounded-lg overflow-hidden shadow-lg group-hover:shadow-xl transition-shadow relative">
              <img
                :if={book.cover_s3_key}
                src={Library.presigned_url(book.cover_s3_key)}
                class="w-full h-full object-cover"
              />
              <div
                :if={!book.cover_s3_key}
                class="w-full h-full flex items-center justify-center text-zinc-500"
              >
                <.icon name="hero-book-open" class="w-12 h-12" />
              </div>
              <div class="absolute inset-0 bg-black/40 opacity-0 group-hover:opacity-100 transition-opacity flex items-center justify-center">
                <.icon name="hero-play-circle" class="w-16 h-16 text-white" />
              </div>
            </div>
            <div class="mt-3">
              <h3 class="font-semibold text-zinc-100 truncate">{book.title}</h3>
              <p class="text-sm text-zinc-400 truncate">{book.author}</p>
            </div>
          </div>
        </div>

        <div
          :if={@playing_book}
          class="fixed bottom-0 left-0 right-0 bg-zinc-900 border-t border-zinc-800 p-4 shadow-2xl"
        >
          <div class="max-w-4xl mx-auto flex items-center gap-6">
            <div class="hidden sm:block w-16 h-16 bg-zinc-800 rounded overflow-hidden flex-shrink-0">
              <img
                :if={@playing_book.cover_s3_key}
                src={Library.presigned_url(@playing_book.cover_s3_key)}
                class="w-full h-full object-cover"
              />
            </div>
            <div class="flex-grow min-w-0">
              <h4 class="font-bold text-zinc-100 truncate">{@playing_book.title}</h4>
              <p class="text-sm text-zinc-400 truncate">{@playing_book.author}</p>
            </div>
            <div class="flex-grow max-w-2xl">
              <audio
                id={"audio-player-#{@playing_book.id}"}
                controls
                autoplay
                src={@audio_url}
                class="w-full h-10"
                phx-hook="AudioPlayer"
                data-book-id={@playing_book.id}
                data-start-at={@start_at}
              >
                Your browser does not support the audio element.
              </audio>
            </div>
            <button phx-click="stop" class="text-zinc-400 hover:text-zinc-100">
              <.icon name="hero-x-mark" class="w-6 h-6" />
            </button>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("play", %{"id" => id}, socket) do
    book = Library.get_book!(id)

    # Mocking play position retrieval.
    # In a real app, you'd fetch this from the database.
    start_at = 0

    # For now, assume all books are single media assets.
    # We'll take the media asset from the first chapter.
    case book.chapters do
      [first_chapter | _] ->
        audio_url = Library.presigned_url(first_chapter.media_asset.s3_key)
        {:noreply, assign(socket, playing_book: book, audio_url: audio_url, start_at: start_at)}

      [] ->
        {:noreply, put_flash(socket, :error, "This book has no audio.")}
    end
  end

  @impl true
  def handle_event("save_position", %{"id" => id, "position" => position}, socket) do
    # Here you would save the position to the database.
    # position is in seconds (float).
    IO.puts("Saving position for book #{id}: #{position}s")
    {:noreply, socket}
  end

  @impl true
  def handle_event("stop", _, socket) do
    {:noreply, assign(socket, playing_book: nil, audio_url: nil, start_at: 0)}
  end
end
