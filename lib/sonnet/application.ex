defmodule Sonnet.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Oban.Telemetry.attach_default_logger()

    children =
      oidc_children() ++
        [
          SonnetWeb.Telemetry,
          Sonnet.Repo,
          {DNSCluster, query: Application.get_env(:sonnet, :dns_cluster_query) || :ignore},
          {Phoenix.PubSub, name: Sonnet.PubSub},
          {Oban, Application.fetch_env!(:sonnet, Oban)},
          # Start a worker by calling: Sonnet.Worker.start_link(arg)
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

  defp oidc_children do
    oidc_config = Application.get_env(:sonnet, Sonnet.OIDC, [])

    if Keyword.get(oidc_config, :start_worker, true) do
      worker_opts =
        %{
          name: Sonnet.OIDC,
          issuer: Keyword.fetch!(oidc_config, :issuer),
          backoff_type: :random_exponential
        }
        |> maybe_put(
          :provider_configuration_opts,
          Keyword.get(oidc_config, :provider_configuration_opts)
        )

      [{Oidcc.ProviderConfiguration.Worker, worker_opts}]
    else
      []
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
