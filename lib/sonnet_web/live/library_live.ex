defmodule SonnetWeb.LibraryLive do
  use SonnetWeb, :live_view
  alias Sonnet.Library

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Library.subscribe()

    {:ok,
     socket
     |> stream(:books, Library.list_books())
     |> assign(
       playing_book: nil,
       playing_chapter: nil,
       audio_url: nil,
       start_at: 0
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="p-6">
        <.header>
          Library
        </.header>

        <div
          id="books"
          phx-update="stream"
          class="grid grid-cols-2 md:grid-cols-4 lg:grid-cols-6 gap-6 mt-8"
        >
          <div
            :for={{id, book} <- @streams.books}
            id={id}
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
    id = String.to_integer(id)

    if socket.assigns.playing_book && socket.assigns.playing_book.id == id do
      {:noreply, socket}
    else
      book = Library.get_book!(id)
      user_id = socket.assigns.current_scope.user.id

      progress = Library.get_listen_progress(user_id, book.id)

      {chapter, offset_ms} =
        if progress && progress.chapter do
          {progress.chapter, progress.offset_ms}
        else
          {List.first(book.chapters), 0}
        end

      case chapter do
        %{media_asset: %{s3_key: s3_key}} ->
          audio_url = Library.presigned_url(s3_key)
          start_at = chapter.start_ms + offset_ms

          {:noreply,
           assign(socket,
             playing_book: book,
             playing_chapter: chapter,
             audio_url: audio_url,
             start_at: start_at
           )}

        _ ->
          {:noreply, put_flash(socket, :error, "This book has no audio.")}
      end
    end
  end

  @impl true
  def handle_event("save_position", %{"id" => id, "position_ms" => position_ms}, socket) do
    user_id = socket.assigns.current_scope.user.id
    book_id = String.to_integer(id)
    playing_book = socket.assigns.playing_book
    playing_chapter = socket.assigns.playing_chapter

    if playing_chapter && playing_chapter.book_id == book_id do
      # Find the chapter that contains this position in the current audio file.
      # This handles crossing boundaries in multi-chapter files (like .m4b).
      new_chapter =
        Enum.find(playing_book.chapters, fn c ->
          c.media_asset_id == playing_chapter.media_asset_id and
            position_ms >= c.start_ms and position_ms < c.end_ms
        end) || playing_chapter

      offset_ms = max(0, position_ms - new_chapter.start_ms)
      Library.save_listen_progress(user_id, book_id, new_chapter.id, offset_ms)

      {:noreply, assign(socket, playing_chapter: new_chapter)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("ended", %{"id" => id}, socket) do
    user_id = socket.assigns.current_scope.user.id
    book_id = String.to_integer(id)
    playing_book = socket.assigns.playing_book
    playing_chapter = socket.assigns.playing_chapter

    if playing_chapter && playing_chapter.book_id == book_id do
      next_chapter =
        Enum.find(playing_book.chapters, fn c ->
          c.position == playing_chapter.position + 1
        end)

      case next_chapter do
        %{media_asset: %{s3_key: s3_key}} = chapter ->
          audio_url = Library.presigned_url(s3_key)
          # Start at the beginning of the new file's chapter range
          start_at = chapter.start_ms

          Library.save_listen_progress(user_id, book_id, chapter.id, 0)

          {:noreply,
           assign(socket,
             playing_chapter: chapter,
             audio_url: audio_url,
             start_at: start_at
           )}

        _ ->
          # No more chapters
          {:noreply, assign(socket, playing_book: nil, playing_chapter: nil, audio_url: nil)}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("stop", _, socket) do
    {:noreply,
     assign(socket, playing_book: nil, playing_chapter: nil, audio_url: nil, start_at: 0)}
  end

  @impl true
  def handle_info(:books_updated, socket) do
    {:noreply, stream(socket, :books, Library.list_books(), reset: true)}
  end
end
