defmodule SonnetWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use SonnetWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="navbar bg-base-100 sticky top-0 z-40 px-4 sm:px-6 lg:px-8 h-16">
      <div class="flex-1">
        <.link navigate={~p"/"} class="flex items-center gap-2 group">
          <div class="bg-primary text-primary-content p-1.5 rounded-lg group-hover:scale-110 transition-transform">
            <.icon name="hero-musical-note" class="size-6" />
          </div>
          <span class="text-xl font-bold tracking-tight">Sonnet</span>
        </.link>
      </div>

      <div class="flex-none gap-2">
        <.theme_toggle />

        <%= if @current_scope.user do %>
          <div class="dropdown dropdown-end">
            <div
              tabindex="0"
              role="button"
              class="btn btn-ghost gap-3 pl-2 pr-1 rounded-full h-10 min-h-0"
            >
              <span class="text-sm font-semibold hidden lg:block">
                {@current_scope.user.name || "User"}
              </span>
              <div class="avatar">
                <div class="w-8 rounded-full ring ring-primary/20 ring-offset-base-100 ring-offset-1">
                  <img
                    alt="Avatar"
                    src={
                      @current_scope.user.avatar_url ||
                        "https://img.daisyui.com/images/stock/photo-1534528741775-53994a69daeb.webp"
                    }
                  />
                </div>
              </div>
            </div>
            <ul
              tabindex="0"
              class="menu menu-sm dropdown-content bg-base-100 rounded-box z-[1] mt-3 w-52 p-2 shadow-xl border border-base-content/10"
            >
              <li class="md:hidden">
                <.link navigate={~p"/library"}>
                  <.icon name="hero-rectangle-stack" class="size-4" /> Library
                </.link>
              </li>
              <li class="md:hidden">
                <.link navigate={~p"/ingest"}>
                  <.icon name="hero-arrow-up-tray" class="size-4" /> Ingest
                </.link>
              </li>
              <li>
                <.link navigate={~p"/users/settings"}>
                  <.icon name="hero-cog-6-tooth" class="size-4" /> Settings
                </.link>
              </li>
              <div class="divider my-1"></div>
              <li>
                <.link href={~p"/users/log-out"} method="delete" class="text-error">
                  <.icon name="hero-arrow-right-on-rectangle" class="size-4" /> Logout
                </.link>
              </li>
            </ul>
          </div>
        <% else %>
          <.link href={~p"/auth/oidc"} class="btn btn-primary btn-sm">Log in</.link>
        <% end %>
      </div>
    </div>

    <main class="px-4 py-8 sm:px-6 lg:px-8">
      <div class="mx-auto max-w-7xl">
        {render_slot(@inner_block)}
      </div>
    </main>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div
      id={@id}
      aria-live="polite"
      class="fixed top-4 right-4 z-50 flex flex-col gap-2 w-full max-w-sm"
    >
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="dropdown dropdown-end">
      <div tabindex="0" role="button" class="btn btn-ghost btn-circle btn-sm">
        <div class="relative size-[1.2rem]">
          <.icon
            name="hero-sun"
            class="absolute inset-0 size-full transition-all scale-100 rotate-0 dark:scale-0 dark:rotate-90"
          />
          <.icon
            name="hero-moon"
            class="absolute inset-0 size-full transition-all scale-0 -rotate-90 dark:scale-100 dark:rotate-0"
          />
        </div>
        <span class="sr-only">Toggle theme</span>
      </div>
      <ul
        tabindex="0"
        class="dropdown-content z-[1] menu p-2 shadow-xl bg-base-100 rounded-box w-32 border border-base-content/10"
      >
        <li>
          <button
            phx-click={JS.dispatch("phx:set-theme")}
            data-phx-theme="light"
            onclick="document.activeElement.blur()"
          >
            <.icon name="hero-sun-micro" class="size-4" /> Light
          </button>
        </li>
        <li>
          <button
            phx-click={JS.dispatch("phx:set-theme")}
            data-phx-theme="dark"
            onclick="document.activeElement.blur()"
          >
            <.icon name="hero-moon-micro" class="size-4" /> Dark
          </button>
        </li>
        <li>
          <button
            phx-click={JS.dispatch("phx:set-theme")}
            data-phx-theme="system"
            onclick="document.activeElement.blur()"
          >
            <.icon name="hero-computer-desktop-micro" class="size-4" /> System
          </button>
        </li>
      </ul>
    </div>
    """
  end
end
