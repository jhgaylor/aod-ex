defmodule AgentOnDemand.Conversations do
  @moduledoc """
  Context for sandboxes (sprite lifespans) and conversations (chat histories).

  Sandboxes own a sprite. Conversations live inside a sandbox and own the
  turn-by-turn chat with a particular agent. v1 keeps these 1:1.
  """

  import Ecto.Query

  alias AgentOnDemand.Conversations.{Conversation, LogEvent, Sandbox, Turn}
  alias AgentOnDemand.Repo

  # ── sandboxes ─────────────────────────────────────────────────────────────

  def list_sandboxes do
    Repo.all(from s in Sandbox, order_by: [desc: s.inserted_at])
  end

  def get_sandbox(id), do: Repo.get(Sandbox, id)
  def get_sandbox!(id), do: Repo.get!(Sandbox, id)

  def create_sandbox(attrs) do
    %Sandbox{}
    |> Sandbox.changeset(attrs)
    |> Repo.insert()
  end

  def update_sandbox(%Sandbox{} = sandbox, attrs) do
    sandbox
    |> Sandbox.changeset(attrs)
    |> Repo.update()
  end

  # ── conversations ─────────────────────────────────────────────────────────

  def list_conversations do
    Repo.all(
      from c in Conversation,
        order_by: [desc: c.inserted_at],
        preload: [:sandbox, :agent]
    )
  end

  @doc """
  Conversations whose `ConversationServer` would have been running at the
  time of a clean BEAM stop: status `idle` or `running`, with a fully-
  provisioned (`ready`) sandbox.
  """
  def list_resumable_conversations do
    Repo.all(
      from c in Conversation,
        join: s in Sandbox,
        on: s.id == c.sandbox_id,
        where: c.status in ["idle", "running"] and s.status == "ready",
        preload: [:sandbox]
    )
  end

  def get_conversation(id) do
    Conversation
    |> Repo.get(id)
    |> Repo.preload([:sandbox, :agent])
  end

  def get_conversation!(id) do
    Conversation
    |> Repo.get!(id)
    |> Repo.preload([:sandbox, :agent])
  end

  def create_conversation(attrs) do
    %Conversation{}
    |> Conversation.changeset(attrs)
    |> Repo.insert()
  end

  def update_conversation(%Conversation{} = conv, attrs) do
    conv
    |> Conversation.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Best-effort terminate the running ConversationServer (destroys the sprite
  if alive), then delete the conversation row. Cascades to turns and log
  events via the FK.
  """
  def delete_conversation(%Conversation{id: id} = conv) do
    _ = AgentOnDemand.Conversations.ConversationServer.terminate(id)
    Repo.delete(conv)
  end

  # ── turns ─────────────────────────────────────────────────────────────────

  def list_turns(conversation_id) do
    Repo.all(
      from t in Turn,
        where: t.conversation_id == ^conversation_id,
        order_by: [asc: t.turn_number]
    )
  end

  def next_turn_number(conversation_id) do
    last =
      Repo.one(
        from t in Turn,
          where: t.conversation_id == ^conversation_id,
          select: max(t.turn_number)
      )

    (last || 0) + 1
  end

  def create_turn(attrs) do
    %Turn{}
    |> Turn.changeset(attrs)
    |> Repo.insert()
  end

  def update_turn(%Turn{} = turn, attrs) do
    turn
    |> Turn.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Mark any `running` turns for the given conversation as `interrupted`.
  Used during reattach: a BEAM restart orphaned whatever turn was in
  flight, and we can't know its outcome — mark it so the user gets a
  clear signal instead of a permanently-stuck status.
  """
  def mark_orphaned_turns_interrupted(conversation_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {n, _} =
      Repo.update_all(
        from(t in Turn,
          where: t.conversation_id == ^conversation_id and t.status == "running"
        ),
        set: [status: "interrupted", ended_at: now]
      )

    n
  end

  # ── log events ────────────────────────────────────────────────────────────

  @doc """
  Insert a log event. Returns the inserted struct (with integer `:id`,
  used as the SSE event id).
  """
  def log!(attrs) do
    attrs = Map.put_new(attrs, :inserted_at, DateTime.utc_now() |> DateTime.truncate(:second))

    %LogEvent{}
    |> LogEvent.changeset(attrs)
    |> Repo.insert!()
  end

  @doc """
  Stream persisted log events for a conversation, ordered by id.
  Optionally start after a given event id (for SSE Last-Event-ID resume).
  """
  def stream_log_events(conversation_id, after_id \\ 0) do
    from(e in LogEvent,
      where: e.conversation_id == ^conversation_id and e.id > ^after_id,
      order_by: [asc: e.id]
    )
    |> Repo.stream(max_rows: 100)
  end

  def list_log_events(conversation_id, after_id \\ 0) do
    Repo.all(
      from e in LogEvent,
        where: e.conversation_id == ^conversation_id and e.id > ^after_id,
        order_by: [asc: e.id]
    )
  end

  # ── high-level lifecycle ──────────────────────────────────────────────────

  alias AgentOnDemand.Agents
  alias AgentOnDemand.Conversations.ConversationServer

  @doc """
  Create a new sandbox + conversation pair, start a ConversationServer
  to drive it, optionally seed with the first prompt. Returns the
  persisted Conversation (preloaded).

  ## Required attrs
    - `agent_id`        — agent to run
    - `prompt`          — optional first prompt (sends turn 1 immediately)
    - `sprite_name`     — optional override; defaults to "conv-<short-id>"
  """
  def start_conversation(%{"agent_id" => agent_id} = attrs) do
    with %Agents.Agent{} = agent <- Agents.get_agent(agent_id) || {:error, :not_found},
         {:ok, runtime_module} <- AgentOnDemand.Runtimes.for_runtime(agent.runtime),
         {:ok, sandbox} <-
           create_sandbox(%{
             environment_id: agent.environment_id,
             sprite_name: attrs["sprite_name"] || "conv-#{short_id()}",
             status: "pending"
           }),
         {:ok, conv} <-
           create_conversation(%{
             sandbox_id: sandbox.id,
             agent_id: agent.id,
             runtime: agent.runtime,
             status: "pending"
           }) do
      {:ok, _pid} =
        DynamicSupervisor.start_child(
          AgentOnDemand.ConversationSupervisor,
          {ConversationServer,
           [
             conversation_id: conv.id,
             sandbox_id: sandbox.id,
             runtime_module: runtime_module,
             initial_prompt: attrs["prompt"]
           ]}
        )

      {:ok, get_conversation!(conv.id)}
    else
      nil -> {:error, :not_found}
      {:error, _} = err -> err
    end
  end

  defp short_id, do: Ecto.UUID.generate() |> binary_part(0, 8)

  @doc """
  Resume a conversation whose ConversationServer is gone (e.g. after a
  BEAM restart, or in the gap between Rehydrator runs).

  Strategy:
  1. If the existing sandbox is `ready` and the sprite is still alive at
     sprites.dev, start a fresh `ConversationServer` pointing at it. The
     server will go through reattach mode and pick up any running
     detachable session.
  2. Otherwise, provision a fresh sprite, mark the old sandbox
     terminated, and start the server pointing at the new sandbox.
     `claude --resume` keeps the chat via the persisted
     `runtime_session_id`.

  Returns `{:error, :gone}` if the conversation is in a terminal status
  (`terminated`, `failed`, `completed`) — those don't auto-resume.
  """
  def wake_conversation(conv_id, initial_prompt \\ nil) do
    with %Conversation{} = conv <- get_conversation(conv_id) || {:error, :not_found},
         :ok <- assert_resumable(conv),
         %Agents.Agent{} = agent <-
           (conv.agent_id && Agents.get_agent(conv.agent_id)) || {:error, :no_agent},
         {:ok, runtime_module} <- AgentOnDemand.Runtimes.for_runtime(conv.runtime) do
      case maybe_reuse_sandbox(conv) do
        {:reuse, sandbox_id} ->
          start_conversation_server(conv, sandbox_id, runtime_module, initial_prompt)

        :create_new ->
          create_fresh_sandbox_and_start(conv, agent, runtime_module, initial_prompt)
      end
    else
      nil -> {:error, :not_found}
      {:error, _} = err -> err
    end
  end

  # Probe the existing sandbox: if it's `ready` and sprites.dev confirms
  # the sprite still exists, we can reattach without provisioning a new
  # one. Otherwise, fall through to creating a fresh sandbox.
  defp maybe_reuse_sandbox(%Conversation{sandbox_id: nil}), do: :create_new

  defp maybe_reuse_sandbox(%Conversation{sandbox_id: sandbox_id}) do
    case get_sandbox(sandbox_id) do
      %{status: "ready", sprite_name: name} when is_binary(name) ->
        client = AgentOnDemand.SpritesClient.get!()

        case Sprites.get_sprite(client, name) do
          {:ok, _info} -> {:reuse, sandbox_id}
          _ -> :create_new
        end

      _ ->
        :create_new
    end
  end

  defp start_conversation_server(conv, sandbox_id, runtime_module, initial_prompt) do
    with {:ok, _pid} <-
           DynamicSupervisor.start_child(
             AgentOnDemand.ConversationSupervisor,
             {ConversationServer,
              [
                conversation_id: conv.id,
                sandbox_id: sandbox_id,
                runtime_module: runtime_module,
                initial_prompt: initial_prompt
              ]}
           ) do
      {:ok, get_conversation!(conv.id)}
    end
  end

  defp create_fresh_sandbox_and_start(conv, agent, runtime_module, initial_prompt) do
    with {:ok, new_sandbox} <-
           create_sandbox(%{
             environment_id: agent.environment_id,
             sprite_name: "conv-#{short_id()}",
             status: "pending"
           }),
         _ <- mark_old_sandbox_terminated(conv.sandbox_id),
         {:ok, conv} <-
           update_conversation(conv, %{sandbox_id: new_sandbox.id, status: "pending"}) do
      start_conversation_server(conv, new_sandbox.id, runtime_module, initial_prompt)
    end
  end

  defp assert_resumable(%Conversation{status: s}) when s in ~w(terminated failed completed) do
    {:error, :gone}
  end

  defp assert_resumable(_), do: :ok

  defp mark_old_sandbox_terminated(nil), do: :ok

  defp mark_old_sandbox_terminated(sandbox_id) do
    case get_sandbox(sandbox_id) do
      nil ->
        :ok

      sb when sb.status in ["terminated", "failed"] ->
        :ok

      sb ->
        update_sandbox(sb, %{
          status: "terminated",
          terminated_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })
    end
  end
end
