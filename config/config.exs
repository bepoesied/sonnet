# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :sonnet, Oban,
  engine: Oban.Engines.Basic,
  queues: [default: 10],
  repo: Sonnet.Repo,
  pruner: [max_age: {7, :days}],
  lifeline: [rescue_after: {30, :minutes}],
  cron: [
    crontab: [
      {"@hourly", Sonnet.Workers.MediaAssetCleanup, args: %{}, max_attempts: 3}
    ]
  ]

config :sonnet, :scopes,
  user: [
    default: true,
    module: Sonnet.Accounts.Scope,
    assign_key: :current_scope,
    access_path: [:user, :id],
    schema_key: :user_id,
    schema_type: :id,
    schema_table: :users,
    test_data_fixture: Sonnet.AccountsFixtures,
    test_setup_helper: :register_and_log_in_user
  ]

config :sonnet,
  ecto_repos: [Sonnet.Repo],
  generators: [timestamp_type: :utc_datetime]

# Configures the endpoint
config :sonnet, SonnetWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: SonnetWeb.ErrorHTML, json: SonnetWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Sonnet.PubSub,
  live_view: [signing_salt: "VCWm51L4"]

config :ueberauth, Ueberauth,
  providers: [
    oidc: {
      Ueberauth.Strategy.Oidcc,
      issuer: :oidcc_issuer,
      scopes: ["openid", "profile", "email"],
      userinfo: true,
      validate_scopes: true
    }
  ]

# Configures the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :sonnet, Sonnet.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  sonnet: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ],
  service_worker: [
    args:
      ~w(js/service-worker.js --bundle --target=es2022 --outfile=../priv/static/service-worker.js),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.7",
  path: "tailwindcss",
  sonnet: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configures Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

config :mime, :types, %{
  "audio/mp4" => ["m4b", "m4a"]
}

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
