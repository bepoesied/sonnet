defmodule SonnetWeb.Router do
  use SonnetWeb, :router

  import SonnetWeb.UserAuth
  import Oban.Web.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {SonnetWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug :fetch_session
    plug :protect_from_forgery_when_using_cookie
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
  end

  scope "/", SonnetWeb do
    pipe_through :browser

    get "/", PageController, :home
    get "/health", HealthCheckController, :index
  end

  # API routes
  scope "/api", SonnetWeb.API do
    pipe_through [:api]

    post "/auth/oidc-login", AuthController, :oidc_login
  end

  scope "/api", SonnetWeb.API do
    pipe_through [:api, :require_authenticated_user]

    get "/books", BookController, :index
    get "/books/:id", BookController, :show
    get "/books/:id/progress", BookController, :progress
    put "/books/:id/progress", BookController, :update_progress
    put "/books/:id/complete", BookController, :complete
    put "/books/:id/incomplete", BookController, :incomplete
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:sonnet, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: SonnetWeb.Telemetry
    end
  end

  # Authenticated routes
  scope "/", SonnetWeb do
    pipe_through [:browser, :require_authenticated_user]

    get "/player/:book_id", PlayerController, :show

    live_session :require_authenticated_user,
      on_mount: [{SonnetWeb.UserAuth, :require_authenticated}] do
      live "/users/settings", UserLive.Settings, :edit
      live "/ingest", BookLive.Ingest, :ingest
      live "/multi-ingest", BookLive.MultiIngest, :ingest
      live "/library", LibraryLive, :index
      live "/library/books/:id/edit", LibraryLive, :edit
    end

    oban_dashboard("/oban")
  end

  scope "/", SonnetWeb do
    pipe_through [:browser]

    delete "/users/log-out", UserSessionController, :delete_web

    get "/auth/:provider", AuthController, :request
    get "/auth/:provider/callback", AuthController, :callback
  end

  scope "/", SonnetWeb do
    pipe_through [:api]

    post "/users/token-refresh", UserSessionController, :refresh
    post "/users/logout", UserSessionController, :delete
  end
end
