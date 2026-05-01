defmodule AgentOnDemand.Factory do
  @moduledoc """
  Test factories for AoD. Lean and explicit — no factory_bot magic.

  Each `*_attrs/1` returns a map suitable for the corresponding context's
  create function. `insert_*/1` skips the changeset and writes the row
  directly so tests can construct invariants the API wouldn't allow (e.g.
  a sandbox in `ready` status without going through provision).
  """

  alias AgentOnDemand.Repo
  alias AgentOnDemand.Conversations.{Conversation, LogEvent, Sandbox, Turn}

  # Cheap unique suffix so names don't collide across test runs in the same
  # SQLite file.
  defp uniq, do: System.unique_integer([:positive, :monotonic]) |> Integer.to_string()

  # ── environments ──────────────────────────────────────────────────────────

  def env_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        "name" => "env-#{uniq()}",
        "packages" => %{},
        "env_vars" => %{},
        "setup_script" => "",
        "networking_type" => "unrestricted",
        "networking_config" => %{},
        "repositories" => []
      },
      stringify_keys(overrides)
    )
  end

  def insert_env(overrides \\ %{}) do
    {:ok, env} = AgentOnDemand.Environments.create_environment(env_attrs(overrides))
    env
  end

  def insert_secret(env, overrides \\ %{}) do
    attrs =
      %{"key" => "TEST_KEY_#{uniq()}", "value" => "test-value-#{uniq()}"}
      |> Map.merge(stringify_keys(overrides))

    {:ok, secret} = AgentOnDemand.Environments.upsert_secret(env, attrs)
    secret
  end

  # ── agents ────────────────────────────────────────────────────────────────

  def agent_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        "name" => "agent-#{uniq()}",
        "model" => "anthropic/claude-sonnet-4-6",
        "runtime" => "claude",
        "skills" => [],
        "mcp_servers" => %{},
        "metadata" => %{}
      },
      stringify_keys(overrides)
    )
  end

  def insert_agent(overrides \\ %{}) do
    {:ok, agent} = AgentOnDemand.Agents.create_agent(agent_attrs(overrides))
    agent
  end

  # ── conversations / sandboxes / turns ─────────────────────────────────────

  def insert_sandbox(overrides \\ %{}) do
    attrs =
      %{
        sprite_name: "test-sprite-#{uniq()}",
        status: "pending"
      }
      |> Map.merge(atomize_keys(overrides))

    %Sandbox{}
    |> Sandbox.changeset(attrs)
    |> Repo.insert!()
  end

  def insert_conversation(overrides \\ %{}) do
    sandbox = overrides[:sandbox] || insert_sandbox()
    agent = overrides[:agent]

    attrs =
      %{
        sandbox_id: sandbox.id,
        agent_id: agent && agent.id,
        runtime: "claude",
        status: "pending"
      }
      |> Map.merge(atomize_keys(Map.drop(overrides, [:sandbox, :agent])))

    %Conversation{}
    |> Conversation.changeset(attrs)
    |> Repo.insert!()
    |> Repo.preload([:sandbox, :agent])
  end

  def insert_turn(conv, overrides \\ %{}) do
    attrs =
      %{
        conversation_id: conv.id,
        turn_number: AgentOnDemand.Conversations.next_turn_number(conv.id),
        prompt: "test prompt",
        status: "pending"
      }
      |> Map.merge(atomize_keys(overrides))

    %Turn{}
    |> Turn.changeset(attrs)
    |> Repo.insert!()
  end

  def insert_log_event(conv, overrides \\ %{}) do
    attrs =
      %{
        conversation_id: conv.id,
        kind: "output",
        stream: "stdout",
        data: "test data",
        inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
      }
      |> Map.merge(atomize_keys(overrides))

    %LogEvent{}
    |> LogEvent.changeset(attrs)
    |> Repo.insert!()
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  defp stringify_keys(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp atomize_keys(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) -> {String.to_existing_atom(k), v}
      {k, v} -> {k, v}
    end)
  rescue
    ArgumentError -> map
  end
end
