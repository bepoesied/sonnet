defmodule SonnetWeb.BookComponents do
  use Phoenix.Component
  import SonnetWeb.CoreComponents
  alias Sonnet.Library

  @doc """
  Renders a book card in a square aspect ratio.
  """
  attr :id, :string, required: true
  attr :book, :any, required: true

  def book_card(assigns) do
    ~H"""
    <div
      id={@id}
      tabindex="0"
      class="card bg-base-200 shadow-xl cursor-pointer transition-transform group focus:outline-none [@media(hover:hover)]:hover:scale-105 [@media(hover:none)]:focus:scale-105 focus-visible:scale-105 has-[:focus-visible]:scale-105"
    >
      <figure class="aspect-square relative overflow-hidden">
        <img
          :if={@book.cover_s3_key}
          src={Library.presigned_url(@book.cover_s3_key)}
          alt={@book.title}
          class="w-full h-full object-cover"
        />
        <div
          :if={!@book.cover_s3_key}
          class="w-full h-full flex items-center justify-center bg-neutral text-neutral-content"
        >
          <.icon name="hero-book-open" class="w-12 h-12" />
        </div>
        <div class="absolute inset-0 bg-black/40 opacity-0 transition-opacity flex items-center justify-center [@media(hover:hover)]:group-hover:opacity-100 [@media(hover:none)]:group-focus:opacity-100 group-focus-visible:opacity-100 group-has-[:focus-visible]:opacity-100">
          <button
            type="button"
            phx-click="play"
            phx-value-id={@book.id}
            class="text-white hover:scale-110 transition-transform focus:outline-none focus-visible:ring-2 focus-visible:ring-white rounded-full"
          >
            <.icon name="hero-play-circle" class="w-16 h-16" />
          </button>
        </div>

        <div class="absolute top-2 right-2 z-10">
          <button
            :if={!@book.is_completed}
            type="button"
            phx-click="mark_complete"
            phx-value-id={@book.id}
            class="text-white/70 hover:text-white opacity-0 transition-opacity [@media(hover:hover)]:group-hover:opacity-100 [@media(hover:none)]:group-focus:opacity-100 group-focus-visible:opacity-100 group-has-[:focus-visible]:opacity-100 focus:outline-none"
            title="Mark as Completed"
          >
            <.icon name="hero-check-circle" class="w-8 h-8" />
          </button>
          <button
            :if={@book.is_completed}
            type="button"
            phx-click="mark_incomplete"
            phx-value-id={@book.id}
            class="text-secondary bg-base-200 rounded-full hover:scale-110 transition-transform focus:outline-none"
            title="Mark as Incomplete"
          >
            <.icon name="hero-check-circle-solid" class="w-8 h-8" />
          </button>
        </div>
      </figure>
      <div class="card-body p-3 sm:p-4 text-center items-center">
        <h2 class="card-title text-sm sm:text-base justify-center">{@book.title}</h2>
        <p class="text-xs opacity-70 truncate w-full">{@book.author}</p>
      </div>
    </div>
    """
  end

  @doc """
  Renders the fixed audio player bar.
  """
  attr :playing_book, :any, required: true
  attr :playing_chapter, :any, default: nil
  attr :audio_url, :string, required: true
  attr :start_at, :integer, required: true

  def player_bar(assigns) do
    ~H"""
    <div
      :if={@playing_book}
      class="fixed bottom-0 left-0 right-0 bg-base-300/95 backdrop-blur-md border-t border-base-content/10 p-2 sm:p-4 shadow-2xl z-50"
    >
      <div class="max-w-5xl mx-auto flex flex-col gap-1 sm:gap-2">
        <div class="flex items-center justify-between gap-3">
          <div class="flex items-center gap-3 min-w-0">
            <div class="w-12 h-12 sm:w-16 sm:h-16 bg-neutral rounded overflow-hidden flex-shrink-0">
              <img
                :if={@playing_book.cover_s3_key}
                src={Library.presigned_url(@playing_book.cover_s3_key)}
                class="w-full h-full object-cover"
              />
            </div>
            <div class="min-w-0">
              <h4 class="font-bold text-sm sm:text-base truncate">{@playing_book.title}</h4>
              <p class="text-xs opacity-70 truncate">{@playing_book.author}</p>
              <p :if={@playing_chapter} class="text-[10px] opacity-50 truncate">
                {@playing_chapter.title}
              </p>
            </div>
          </div>
          <button phx-click="stop" class="btn btn-ghost btn-circle btn-sm sm:btn-md">
            <.icon name="hero-x-mark" class="w-5 h-5 sm:w-6 sm:h-6" />
          </button>
        </div>

        <div class="w-full">
          <audio
            id={"audio-player-#{@playing_book.id}"}
            controls
            autoplay
            preload="auto"
            src={"#{@audio_url}#t=#{@start_at / 1000}"}
            class="w-full h-10"
            phx-hook="AudioPlayer"
            phx-update="ignore"
            data-book-id={@playing_book.id}
            data-start-at={@start_at}
            data-title={@playing_book.title}
            data-author={@playing_book.author}
            data-cover-url={
              @playing_book.cover_s3_key && Library.presigned_url(@playing_book.cover_s3_key)
            }
            data-chapter-title={@playing_chapter && @playing_chapter.title}
          >
            Your browser does not support the audio element.
          </audio>
        </div>
      </div>
    </div>
    """
  end
end
