defmodule Factory.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      FactoryWeb.Telemetry,
      Factory.Repo,
      {DNSCluster, query: Application.get_env(:factory, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Factory.PubSub},
      {Registry, keys: :unique, name: Factory.Kiro.Registry},
      {DynamicSupervisor, name: Factory.Kiro.Supervisor, strategy: :one_for_one},
      {Task.Supervisor, name: Factory.TaskSupervisor},
      # No Kiro session or review survives a restart: clear leftover context and statuses.
      {Task,
       fn ->
         Factory.Agents.reset_sessions()
         Factory.Specs.reset_reviews()
       end},
      # Start a worker by calling: Factory.Worker.start_link(arg)
      # {Factory.Worker, arg},
      # Start to serve requests, typically the last entry
      FactoryWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Factory.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    FactoryWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
