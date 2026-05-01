defmodule AgentOnDemand.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    AgentOnDemandWeb.Plugs.RateLimit.ensure_table()
    AgentOnDemand.Telemetry.attach_default_logger()

    # OpenTelemetry instrumentation. opentelemetry_phoenix + _ecto attach
    # to the standard telemetry events those libs emit; OpentelemetryTelemetry
    # bridges our custom :agent_on_demand events into OTel spans.
    OpentelemetryPhoenix.setup(adapter: :bandit)
    OpentelemetryEcto.setup([:agent_on_demand, :repo])
    AgentOnDemand.Telemetry.attach_otel_bridge()

    cluster_topologies = Application.get_env(:libcluster, :topologies, [])

    children =
      [
        AgentOnDemandWeb.Telemetry,
        AgentOnDemand.Repo,
        {Ecto.Migrator,
         repos: Application.fetch_env!(:agent_on_demand, :ecto_repos), skip: skip_migrations?()},
        {DNSCluster, query: Application.get_env(:agent_on_demand, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: AgentOnDemand.PubSub}
      ] ++
        cluster_children(cluster_topologies) ++
        [
          # Horde.Registry + Horde.DynamicSupervisor are CRDT-backed
          # cluster-aware replacements. Single-node behavior is
          # unchanged; on multiple nodes they sync state and let
          # processes be addressed across the cluster.
          {Horde.Registry,
           [name: AgentOnDemand.ConversationRegistry, keys: :unique, members: :auto]},
          {Horde.DynamicSupervisor,
           [
             name: AgentOnDemand.ConversationSupervisor,
             strategy: :one_for_one,
             distribution_strategy: Horde.UniformDistribution,
             members: :auto
           ]},
          AgentOnDemandWeb.Endpoint
        ]

    opts = [strategy: :one_for_one, name: AgentOnDemand.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, sup} ->
        # Rehydrate ConversationServers for non-terminal conversations whose
        # sprite was fully provisioned at the last clean stop. Done in a
        # detached process so a failure here doesn't block app boot.
        unless skip_rehydrate?(),
          do: Task.start(fn -> AgentOnDemand.Conversations.Rehydrator.run() end)

        {:ok, sup}

      err ->
        err
    end
  end

  defp cluster_children([]), do: []

  defp cluster_children(topologies) do
    [{Cluster.Supervisor, [topologies, [name: AgentOnDemand.ClusterSupervisor]]}]
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    AgentOnDemandWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp skip_migrations?() do
    # By default, sqlite migrations are run when using a release
    System.get_env("RELEASE_NAME") == nil
  end

  # Tests opt out via config; everything else (mix phx.server, releases,
  # iex -S mix phx.server) should rehydrate so we recover from a clean
  # BEAM stop.
  defp skip_rehydrate? do
    Application.get_env(:agent_on_demand, :skip_rehydrate, false)
  end
end
