import Config

config :ex_aws,
  access_key_id: "minioadmin",
  secret_access_key: "minioadmin"

config :sonnet,
  ingest_bucket: "sonnet-dev",
  ingest_prefix: ""

config :ex_aws, :s3,
  host: "localhost",
  scheme: "http://",
  region: "us-east-1",
  port: 9000

config :ueberauth_oidcc, :issuers, [
  %{
    name: :oidcc_issuer,
    issuer: "http://localhost:8080/realms/dev",
    provider_configuration_opts: %{
      quirks: %{
        allow_unsafe_http: true,
        document_overrides: %{
          "pushed_authorization_request_endpoint" => :undefined,
          "token_endpoint_auth_methods_supported" => ["client_secret_basic"],
          "introspection_endpoint_auth_methods_supported" => ["client_secret_basic"],
          "request_object_signing_alg_values_supported" => ["none"]
        }
      }
    }
  }
]

config :ueberauth_oidcc, :providers,
  oidc: [
    issuer: :oidcc_issuer,
    client_id: "sonnet-dev",
    client_secret: "T1dDHQVaoiFAgQyBQx6Ue3NtG2UTDD01",
    scopes: ["openid", "profile"],
    uid_field: "sub",
    callback_path: "/auth/oidc/callback"
  ]

# Configure your database
config :sonnet, Sonnet.Repo,
  username: "sonnet",
  password: "sonnet",
  hostname: "localhost",
  database: "sonnet_dev",
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

# For development, we disable any cache and enable
# debugging and code reloading.
#
# The watchers configuration can be used to run external
# watchers to your application. For example, we can use it
# to bundle .js and .css sources.
config :sonnet, SonnetWeb.Endpoint,
  https: [
    port: 4001,
    cipher_suite: :strong,
    keyfile: "priv/cert/selfsigned_key.pem",
    certfile: "priv/cert/selfsigned.pem"
  ],
  http: [ip: {0, 0, 0, 0}, port: String.to_integer(System.get_env("PORT") || "4000")],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "clMc/BHTzPlZMN2zMG4RWIyakTG9kcOFvjaHOSzi1mPsChUPaPWx1CIkwZ7oy9SX",
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:sonnet, ~w(--sourcemap=inline --watch)]},
    esbuild: {Esbuild, :install_and_run, [:service_worker, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:sonnet, ~w(--watch)]}
  ]

# Watch static and templates for browser reloading.
config :sonnet, SonnetWeb.Endpoint,
  live_reload: [
    web_console_logger: true,
    patterns: [
      ~r"priv/static/(?!uploads/).*(js|css|png|jpeg|jpg|gif|svg)$",
      ~r"priv/gettext/.*(po)$",
      ~r"lib/sonnet_web/(?:controllers|live|components|router)/?.*\.(ex|heex)$"
    ]
  ]

# Enable dev routes for dashboard and mailbox
config :sonnet, dev_routes: true

# Do not include metadata nor timestamps in development logs
config :logger, :default_formatter, format: "[$level] $message\n"

# Set a higher stacktrace during development. Avoid configuring such
# in production as building large stacktraces may be expensive.
config :phoenix, :stacktrace_depth, 20

# Initialize plugs at runtime for faster development compilation
config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view,
  # Include debug annotations and locations in rendered markup.
  # Changing this configuration will require mix clean and a full recompile.
  debug_heex_annotations: true,
  debug_attributes: true,
  # Enable helpful, but potentially expensive runtime checks
  enable_expensive_runtime_checks: true

# Disable swoosh api client as it is only required for production adapters.
config :swoosh, :api_client, false
