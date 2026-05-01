defmodule AgentOnDemand.Agents.Agent do
  use Ecto.Schema
  import Ecto.Changeset

  alias AgentOnDemand.Environments.Environment

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @runtimes ~w(claude codex gemini opencode)

  schema "agents" do
    field :name, :string
    field :description, :string, default: ""
    field :system, :string, default: ""
    field :model, :string
    field :runtime, :string
    field :skills, {:array, :string}, default: []
    field :mcp_servers, :map, default: %{}
    field :metadata, :map, default: %{}
    belongs_to :environment, Environment
    timestamps(type: :utc_datetime)
  end

  def runtimes, do: @runtimes

  def changeset(agent, attrs) do
    agent
    |> cast(attrs, [
      :name,
      :description,
      :system,
      :model,
      :runtime,
      :skills,
      :mcp_servers,
      :metadata,
      :environment_id
    ])
    |> validate_required([:name, :model, :runtime])
    |> validate_inclusion(:runtime, @runtimes)
    |> validate_format(:model, ~r{^[a-z0-9_-]+/[a-z0-9._-]+$},
      message: "must be in canonical provider/model_id form"
    )
    |> validate_length(:name, min: 1, max: 200)
    |> unique_constraint(:name)
    |> assoc_constraint(:environment)
  end
end
