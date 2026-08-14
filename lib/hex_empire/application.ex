defmodule HexEmpire.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      HexEmpireWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:hex_empire, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: HexEmpire.PubSub},
      HexEmpire.GameStore,
      {Registry, keys: :unique, name: HexEmpire.MatchRegistry},
      {DynamicSupervisor, name: HexEmpire.MatchSupervisor, strategy: :one_for_one},
      # Start to serve requests, typically the last entry
      HexEmpireWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: HexEmpire.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    HexEmpireWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
