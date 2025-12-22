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
      class="cursor-pointer group"
      phx-click="play"
      phx-value-id={@book.id}
    >
      <div class="aspect-square bg-zinc-800 rounded-lg overflow-hidden shadow-lg group-hover:shadow-xl transition-shadow relative">
        <img
          :if={@book.cover_s3_key}
          src={Library.presigned_url(@book.cover_s3_key)}
          class="w-full h-full object-cover"
        />
        <div
          :if={!@book.cover_s3_key}
          class="w-full h-full flex items-center justify-center text-zinc-500"
        >
          <.icon name="hero-book-open" class="w-12 h-12" />
        </div>
        <div class="absolute inset-0 bg-black/40 opacity-0 group-hover:opacity-100 transition-opacity flex items-center justify-center">
          <.icon name="hero-play-circle" class="w-16 h-16 text-white" />
        </div>
      </div>
      <div class="mt-4 text-center">
        <h3 class="text-lg font-bold text-zinc-100 leading-tight">{@book.title}</h3>
        <p class="text-zinc-400 mt-1.5 truncate">{@book.author}</p>
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
      class="fixed bottom-0 left-0 right-0 bg-zinc-900/95 backdrop-blur-md border-t border-zinc-800 p-4 shadow-2xl z-50"
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
          <p :if={@playing_chapter} class="text-xs text-zinc-500 mt-0.5 truncate">
            {@playing_chapter.title}
          </p>
        </div>
        <div class="flex-grow max-w-2xl">
          <audio
            id={"audio-player-#{@playing_book.id}"}
            controls
            autoplay
            preload="auto"
            src={"#{@audio_url}#t=#{@start_at / 1000}"}
            class="w-full h-10"
            phx-hook="AudioPlayer"
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
        <button phx-click="stop" class="text-zinc-400 hover:text-zinc-100 transition-colors">
          <.icon name="hero-x-mark" class="w-6 h-6" />
        </button>
      </div>
    </div>
    """
  end
end
