defmodule SonnetWeb.UserLive.Settings do
  use SonnetWeb, :live_view

  on_mount {SonnetWeb.UserAuth, :require_sudo_mode}

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
          <div>
            <h1 class="text-4xl font-bold tracking-tight">Account Settings</h1>
            <p class="text-base-content/70 mt-1">
              Manage your account email address and password settings
            </p>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:trigger_submit, false)

    {:ok, socket}
  end
end
