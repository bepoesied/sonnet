defmodule SonnetWeb.BookComponents do
  use Phoenix.Component
  use SonnetWeb, :verified_routes
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
          <.link
            navigate={~p"/player/#{@book.id}"}
            class="text-white hover:scale-110 transition-transform focus:outline-none focus-visible:ring-2 focus-visible:ring-white rounded-full"
          >
            <.icon name="hero-play-circle" class="w-16 h-16" />
          </.link>
        </div>

        <div class="absolute top-2 right-2 z-10 flex gap-2">
          <.link
            patch={~p"/library/books/#{@book.id}/edit"}
            class="text-white/70 hover:text-white opacity-0 transition-opacity [@media(hover:hover)]:group-hover:opacity-100 [@media(hover:none)]:group-focus:opacity-100 group-focus-visible:opacity-100 group-has-[:focus-visible]:opacity-100 focus:outline-none"
            title="Edit Book"
          >
            <.icon name="hero-pencil" class="w-8 h-8" />
          </.link>
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
end
