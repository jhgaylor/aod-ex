defmodule AgentOnDemand.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    AgentOnDemandWeb.Plugs.RateLimit.ensure_table()
    AgentOnDemand.Telemetry.attach_default_logger()

    children = [
      AgentOnDemandWeb.Telemetry,
      AgentOnDemand.Repo,
      {Ecto.Migrator,
       repos: Application.fetch_env!(:agent_on_demand, :ecto_repos), skip: skip_migrations?()},
      {DNSCluster, query: Application.get_env(:agent_on_demand, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: AgentOnDemand.PubSub},
      {Registry, keys: :unique, name: AgentOnDemand.ConversationRegistry},
      {DynamicSupervisor, name: AgentOnDemand.ConversationSupervisor, strategy: :one_for_one},
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
