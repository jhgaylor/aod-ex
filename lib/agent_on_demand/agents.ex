defmodule AgentOnDemand.Agents do
  @moduledoc "Context for agent definitions."

  import Ecto.Query, only: [from: 2]

  alias AgentOnDemand.Agents.Agent
  alias AgentOnDemand.Repo

  def list_agents do
    Repo.all(from a in Agent, order_by: [desc: a.inserted_at, desc: a.id], preload: [:environment])
  end

  def get_agent(id), do: Repo.get(Agent, id) |> Repo.preload(:environment)
  def get_agent!(id), do: Repo.get!(Agent, id) |> Repo.preload(:environment)

  def create_agent(attrs) do
    %Agent{}
    |> Agent.changeset(attrs)
    |> Repo.insert()
  end

  def update_agent(%Agent{} = agent, attrs) do
    agent
    |> Agent.changeset(attrs)
    |> Repo.update()
  end

  def delete_agent(%Agent{} = agent), do: Repo.delete(agent)
end
