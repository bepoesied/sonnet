defmodule SonnetWeb.LibraryLive do
  use SonnetWeb, :live_view
  alias Sonnet.Library

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Library.subscribe()
    user_id = socket.assigns.current_scope.user.id

    {:ok,
     socket
     |> stream(:books, Library.list_books(user_id))
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
      <div class="container mx-auto pb-32">
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

        <.player_bar
          playing_book={@playing_book}
          playing_chapter={@playing_chapter}
          audio_url={@audio_url}
          start_at={@start_at}
        />
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("play", %{"id" => id}, socket) do
    id = String.to_integer(id)
    user_id = socket.assigns.current_scope.user.id

    if socket.assigns.playing_book && socket.assigns.playing_book.id == id do
      {:noreply, socket}
    else
      book = Library.get_book_with_status!(id, user_id)

      progress = Library.get_listen_progress(user_id, book.id)

      {chapter, offset_ms, should_reset} =
        cond do
          book.is_completed ->
            {List.first(book.chapters), 0, true}

          progress && progress.chapter ->
            {progress.chapter, progress.offset_ms, false}

          true ->
            {List.first(book.chapters), 0, false}
        end

      if should_reset do
        Library.save_listen_progress(user_id, book.id, chapter.id, offset_ms, false)
      end

      case chapter do
        %{media_asset: %{s3_key: s3_key}} ->
          audio_url = Library.presigned_url(s3_key)
          start_at = chapter.start_ms + offset_ms

          socket =
            if should_reset do
              # Refresh book state in stream if it was completed
              updated_book = %{book | is_completed: false}
              stream_insert(socket, :books, updated_book)
            else
              socket
            end

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
          Library.mark_book_complete(user_id, book_id, playing_chapter.id)
          updated_book = Library.get_book_with_status!(book_id, user_id)

          {:noreply,
           socket
           |> assign(playing_book: nil, playing_chapter: nil, audio_url: nil)
           |> stream_insert(:books, updated_book)}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("next_chapter", %{"id" => id}, socket) do
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
          start_at = chapter.start_ms

          Library.save_listen_progress(user_id, book_id, chapter.id, 0)

          {:noreply,
           assign(socket,
             playing_chapter: chapter,
             audio_url: audio_url,
             start_at: start_at
           )}

        _ ->
          {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("previous_chapter", %{"id" => id}, socket) do
    user_id = socket.assigns.current_scope.user.id
    book_id = String.to_integer(id)
    playing_book = socket.assigns.playing_book
    playing_chapter = socket.assigns.playing_chapter

    if playing_chapter && playing_chapter.book_id == book_id do
      prev_chapter =
        Enum.find(playing_book.chapters, fn c ->
          c.position == playing_chapter.position - 1
        end)

      case prev_chapter do
        %{media_asset: %{s3_key: s3_key}} = chapter ->
          audio_url = Library.presigned_url(s3_key)
          start_at = chapter.start_ms

          Library.save_listen_progress(user_id, book_id, chapter.id, 0)

          {:noreply,
           assign(socket,
             playing_chapter: chapter,
             audio_url: audio_url,
             start_at: start_at
           )}

        _ ->
          {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("mark_complete", %{"id" => id}, socket) do
    book_id = String.to_integer(id)
    user_id = socket.assigns.current_scope.user.id
    book = Library.get_book!(book_id)

    # Use first chapter if no progress exists
    chapter_id =
      case Library.get_listen_progress(user_id, book_id) do
        nil -> List.first(book.chapters).id
        progress -> progress.chapter_id
      end

    Library.mark_book_complete(user_id, book_id, chapter_id)

    # Stop if playing
    socket =
      if socket.assigns.playing_book && socket.assigns.playing_book.id == book_id do
        assign(socket, playing_book: nil, playing_chapter: nil, audio_url: nil, start_at: 0)
      else
        socket
      end

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
  def handle_event("stop", _, socket) do
    {:noreply,
     assign(socket, playing_book: nil, playing_chapter: nil, audio_url: nil, start_at: 0)}
  end

  @impl true
  def handle_info(:books_updated, socket) do
    user_id = socket.assigns.current_scope.user.id
    {:noreply, stream(socket, :books, Library.list_books(user_id), reset: true)}
  end
end
