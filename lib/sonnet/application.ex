defmodule Sonnet.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      SonnetWeb.Telemetry,
      Sonnet.Repo,
      {DNSCluster, query: Application.get_env(:sonnet, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Sonnet.PubSub},
      # Start a worker by calling: Sonnet.Worker.start_link(arg)
      {Sonnet.Ingest, bucket: "", prefix: ""},
      # {Sonnet.Worker, arg},
      # Start to serve requests, typically the last entry
      SonnetWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Sonnet.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    SonnetWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
