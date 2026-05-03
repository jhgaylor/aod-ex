defmodule AgentOnDemand.Conversations.Conversation do
  use Ecto.Schema
  import Ecto.Changeset

  alias AgentOnDemand.Agents.Agent
  alias AgentOnDemand.Conversations.{Sandbox, Turn}
  alias AgentOnDemand.Vaults.Vault

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(pending running idle completed failed terminated)

  schema "conversations" do
    field :runtime, :string
    field :status, :string, default: "pending"
    field :runtime_session_id, :string
    belongs_to :sandbox, Sandbox
    belongs_to :agent, Agent
    belongs_to :vault, Vault
    has_many :turns, Turn
    timestamps(type: :utc_datetime)
  end

  def statuses, do: @statuses

  def changeset(conv, attrs) do
    conv
    |> cast(attrs, [:runtime, :status, :runtime_session_id, :sandbox_id, :agent_id, :vault_id])
    |> validate_required([:runtime, :status, :sandbox_id])
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:sandbox_id)
    |> foreign_key_constraint(:agent_id)
    |> foreign_key_constraint(:vault_id)
  end
end
