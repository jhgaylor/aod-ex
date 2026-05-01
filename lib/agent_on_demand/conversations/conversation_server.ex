defmodule AgentOnDemand.Conversations.ConversationServer do
  @moduledoc """
  Owns one running conversation: its sprite, the active runtime command (if
  any), and the per-turn state. Streams sprite stdout/stderr into the DB
  (LogEvent rows) and broadcasts on Phoenix.PubSub topic `"conv:<id>"` so
  SSE subscribers can tail it live.

  Lifecycle:
    pending → starting → ready ⇄ running → terminated|failed
  """

  use GenServer, restart: :transient
  require Logger

  alias AgentOnDemand.{Agents, Conversations, Environments, SpritesClient}

  # ── public api ────────────────────────────────────────────────────────────

  def start_link(args) do
    conv_id = Keyword.fetch!(args, :conversation_id)
    GenServer.start_link(__MODULE__, args, name: via(conv_id))
  end

  def via(conv_id), do: {:via, Registry, {AgentOnDemand.ConversationRegistry, conv_id}}

  def whereis(conv_id) do
    case Registry.lookup(AgentOnDemand.ConversationRegistry, conv_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc """
  Send another prompt. If the conversation's GenServer is gone (e.g. server
  restart), transparently wake the conversation — provision a fresh sprite
  and queue this prompt as the first turn of the new sandbox. claude
  `--resume` preserves the chat via the persisted runtime_session_id.
  """
  def send_prompt(conv_id, prompt) do
    case whereis(conv_id) do
      nil ->
        case Conversations.wake_conversation(conv_id, prompt) do
          {:ok, _conv} -> :ok
          {:error, :gone} -> {:error, :gone}
          {:error, :not_found} -> {:error, :not_running}
          {:error, _} = err -> err
        end

      pid ->
        GenServer.call(pid, {:send_prompt, prompt}, 30_000)
    end
  end

  def interrupt(conv_id) do
    case whereis(conv_id) do
      nil -> {:error, :not_running}
      pid -> GenServer.call(pid, :interrupt, 30_000)
    end
  end

  @doc """
  Terminate the conversation. If the GenServer is alive, it tears down the
  sprite. If not, just mark the DB rows terminated so the user can still
  clean up dead conversations after a server restart.
  """
  def terminate(conv_id) do
    case whereis(conv_id) do
      nil ->
        case Conversations.get_conversation(conv_id) do
          nil ->
            {:error, :not_running}

          conv ->
            now = DateTime.utc_now() |> DateTime.truncate(:second)
            {:ok, _} = Conversations.update_conversation(conv, %{status: "terminated"})

            if conv.sandbox_id do
              sb = Conversations.get_sandbox!(conv.sandbox_id)

              if sb.status not in ["terminated", "failed"] do
                Conversations.update_sandbox(sb, %{status: "terminated", terminated_at: now})
              end
            end

            :ok
        end

      pid ->
        GenServer.call(pid, :terminate_conv, 30_000)
    end
  end

  # ── GenServer ─────────────────────────────────────────────────────────────

  @impl true
  def init(args) do
    state = %{
      conversation_id: Keyword.fetch!(args, :conversation_id),
      sandbox_id: Keyword.fetch!(args, :sandbox_id),
      runtime_module: Keyword.fetch!(args, :runtime_module),
      initial_prompt: Keyword.get(args, :initial_prompt),
      sprite: nil,
      sprite_env: [],
      current_command: nil,
      current_command_ref: nil,
      current_turn: nil,
      runtime_session_id: nil
    }

    {:ok, state, {:continue, :provision}}
  end

  @impl true
  def handle_continue(:provision, state) do
    conv = Conversations.get_conversation!(state.conversation_id)
    sandbox = Conversations.get_sandbox!(state.sandbox_id)
    agent = if conv.agent_id, do: Agents.get_agent!(conv.agent_id), else: nil
    env = if agent && agent.environment_id, do: Environments.get_environment(agent.environment_id)
    secrets = if env, do: Environments.decrypted_env(env), else: %{}
    state = %{state | runtime_session_id: conv.runtime_session_id}

    {:ok, _} = Conversations.update_sandbox(sandbox, %{status: "starting"})
    publish_stage(state.conversation_id, "provision", "started")

    case create_sprite(sandbox.sprite_name) do
      {:ok, sprite} ->
        skill_names = (agent && agent.skills) || []
        AgentOnDemand.SpriteSkills.mount(sprite, skill_names)

        sprite_env =
          (state.runtime_module.default_env(agent) || []) ++
            aod_callback_env() ++
            if(env,
              do: Enum.map(env.env_vars, fn {k, v} -> {to_string(k), to_string(v)} end),
              else: []
            ) ++
            Enum.map(secrets, fn {k, v} -> {k, v} end)

        # Write runtime-specific config (e.g. claude's ~/.claude.json for MCP).
        write_runtime_config(sprite, state.runtime_module, agent)

        with :ok <-
               AgentOnDemand.Conversations.Provisioning.apply_network_policy(
                 sprite,
                 env,
                 state.conversation_id
               ),
             :ok <-
               AgentOnDemand.Conversations.Provisioning.install_packages(
                 sprite,
                 env,
                 sprite_env,
                 state.conversation_id
               ),
             :ok <-
               AgentOnDemand.Conversations.Provisioning.clone_repositories(
                 sprite,
                 env,
                 secrets,
                 state.conversation_id
               ),
             :ok <- run_setup_script(sprite, env, sprite_env, state.conversation_id) do
          {:ok, _} = Conversations.update_sandbox(sandbox, %{status: "ready"})
          publish_stage(state.conversation_id, "provision", "done")

          new_state = %{state | sprite: sprite, sprite_env: sprite_env}

          case state.initial_prompt do
            nil -> {:noreply, new_state}
            p -> {:noreply, kick_turn(new_state, p, agent)}
          end
        else
          {:error, reason} ->
            Logger.error("provision step failed: #{inspect(reason)}")
            _ = Sprites.destroy(sprite)
            {:ok, _} = Conversations.update_sandbox(sandbox, %{status: "failed"})

            publish_stage(state.conversation_id, "provision", "failed", %{
              reason: inspect(reason)
            })

            Conversations.update_conversation(conv, %{status: "failed"})
            {:stop, :normal, state}
        end

      {:error, reason} ->
        Logger.error("sprite provision failed: #{inspect(reason)}")
        {:ok, _} = Conversations.update_sandbox(sandbox, %{status: "failed"})
        publish_stage(state.conversation_id, "provision", "failed", %{reason: inspect(reason)})
        Conversations.update_conversation(conv, %{status: "failed"})
        {:stop, :normal, state}
    end
  end

  defp run_setup_script(_sprite, nil, _sprite_env, _conv_id), do: :ok
  defp run_setup_script(_sprite, %{setup_script: ""}, _sprite_env, _conv_id), do: :ok

  defp run_setup_script(sprite, %{setup_script: script}, sprite_env, conv_id) do
    publish_stage(conv_id, "setup", "started")

    {output, code} =
      Sprites.cmd(sprite, "bash", ["-lc", script],
        env: sprite_env,
        stderr_to_stdout: true,
        timeout: 120_000
      )

    Conversations.log!(%{
      conversation_id: conv_id,
      kind: "output",
      stream: "stdout",
      data: output
    })

    if code == 0 do
      publish_stage(conv_id, "setup", "done", %{exit_code: code})
      :ok
    else
      publish_stage(conv_id, "setup", "failed", %{exit_code: code})
      {:error, {:setup_exit, code}}
    end
  end

  defp write_runtime_config(sprite, runtime_module, agent) do
    if function_exported?(runtime_module, :write_config, 2) do
      runtime_module.write_config(sprite, agent)
    end
  end

  @impl true
  def handle_call({:send_prompt, prompt}, _from, state) do
    if state.current_command do
      {:reply, {:error, :busy}, state}
    else
      conv = Conversations.get_conversation!(state.conversation_id)
      agent = if conv.agent_id, do: Agents.get_agent!(conv.agent_id)
      {:reply, :ok, kick_turn(state, prompt, agent)}
    end
  end

  def handle_call(:interrupt, _from, %{current_command: nil} = state) do
    {:reply, {:error, :idle}, state}
  end

  def handle_call(:interrupt, _from, state) do
    cmd_pid = state.current_command.pid

    if Process.alive?(cmd_pid) do
      try do
        GenServer.stop(cmd_pid, :normal, 1_000)
      catch
        :exit, _ -> :ok
      end
    end

    {:ok, _turn} =
      Conversations.update_turn(state.current_turn, %{
        status: "interrupted",
        ended_at: now()
      })

    publish_stage(state.conversation_id, "turn", "interrupted", %{
      turn_id: state.current_turn.id,
      turn_number: state.current_turn.turn_number
    })

    conv = Conversations.get_conversation!(state.conversation_id)
    {:ok, _} = Conversations.update_conversation(conv, %{status: "idle"})

    {:reply, :ok, %{state | current_command: nil, current_command_ref: nil, current_turn: nil}}
  end

  def handle_call(:terminate_conv, _from, state) do
    if state.sprite, do: _ = Sprites.destroy(state.sprite)
    sandbox = Conversations.get_sandbox!(state.sandbox_id)

    {:ok, _} =
      Conversations.update_sandbox(sandbox, %{status: "terminated", terminated_at: now()})

    conv = Conversations.get_conversation!(state.conversation_id)
    {:ok, _} = Conversations.update_conversation(conv, %{status: "terminated"})
    publish_stage(state.conversation_id, "terminate", "done")
    {:stop, :normal, :ok, state}
  end

  @impl true
  def handle_info({:stdout, %{ref: ref}, data}, %{current_command_ref: ref} = state) do
    log_output(state, "stdout", data)
    {:noreply, state}
  end

  def handle_info({:stderr, %{ref: ref}, data}, %{current_command_ref: ref} = state) do
    log_output(state, "stderr", data)
    {:noreply, state}
  end

  def handle_info({:exit, %{ref: ref}, code}, %{current_command_ref: ref} = state) do
    turn = state.current_turn

    {:ok, turn} =
      Conversations.update_turn(turn, %{
        status: if(code == 0, do: "completed", else: "failed"),
        exit_code: code,
        ended_at: now()
      })

    publish_stage(state.conversation_id, "turn", "done", %{
      turn_id: turn.id,
      turn_number: turn.turn_number,
      exit_code: code
    })

    conv = Conversations.get_conversation!(state.conversation_id)
    {:ok, _} = Conversations.update_conversation(conv, %{status: "idle"})

    {:noreply, %{state | current_command: nil, current_command_ref: nil, current_turn: nil}}
  end

  def handle_info({:error, _ref, reason}, state) do
    Logger.error("sprite command error: #{inspect(reason)}")
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── helpers ───────────────────────────────────────────────────────────────

  defp create_sprite(name) do
    client = SpritesClient.get!()
    Sprites.create(client, name)
  end

  defp aod_callback_env do
    base = Application.get_env(:agent_on_demand, :public_url)
    token = Application.get_env(:agent_on_demand, :admin_token)

    if is_binary(base) and base != "" and is_binary(token) do
      [{"AOD_BASE_URL", base}, {"AOD_TOKEN", token}]
    else
      []
    end
  end

  defp kick_turn(state, prompt, agent) do
    conv = Conversations.get_conversation!(state.conversation_id)
    turn_number = Conversations.next_turn_number(state.conversation_id)

    {:ok, turn} =
      Conversations.create_turn(%{
        conversation_id: conv.id,
        turn_number: turn_number,
        prompt: prompt,
        status: "running",
        started_at: now()
      })

    {:ok, _} = Conversations.update_conversation(conv, %{status: "running"})

    mode =
      cond do
        is_nil(state.runtime_session_id) -> :run
        true -> :continue
      end

    runtime_session_id =
      case state.runtime_session_id do
        nil ->
          # Generate one and persist immediately so a server restart can resume.
          # claude uses --session-id <X> verbatim, so this is the value claude
          # will know us by; turn 2+ will pass --resume <X>.
          new_id = Ecto.UUID.generate()
          {:ok, _} = Conversations.update_conversation(conv, %{runtime_session_id: new_id})
          new_id

        existing ->
          existing
      end

    {cmd, args, _opts} =
      state.runtime_module.build_command(agent, prompt, mode, runtime_session_id, [])

    publish_stage(state.conversation_id, "turn", "started", %{
      turn_id: turn.id,
      turn_number: turn_number,
      mode: Atom.to_string(mode)
    })

    case Sprites.spawn(state.sprite, cmd, args,
           env: state.sprite_env,
           owner: self(),
           stdin: true
         ) do
      {:ok, command} ->
        :ok = Sprites.write(command, prompt)
        :ok = Sprites.close_stdin(command)

        %{
          state
          | current_command: command,
            current_command_ref: command.ref,
            current_turn: turn,
            runtime_session_id: runtime_session_id
        }

      {:error, reason} ->
        Logger.error("spawn failed: #{inspect(reason)}")

        {:ok, _} =
          Conversations.update_turn(turn, %{
            status: "failed",
            ended_at: now()
          })

        publish_stage(state.conversation_id, "turn", "failed", %{
          turn_id: turn.id,
          reason: inspect(reason)
        })

        state
    end
  end

  defp log_output(state, stream, data) do
    event =
      Conversations.log!(%{
        conversation_id: state.conversation_id,
        turn_id: state.current_turn && state.current_turn.id,
        kind: "output",
        stream: stream,
        data: data
      })

    Phoenix.PubSub.broadcast(
      AgentOnDemand.PubSub,
      "conv:#{state.conversation_id}",
      {:log_event, event}
    )
  end

  defp publish_stage(conv_id, stage, state, meta \\ %{}) do
    event =
      Conversations.log!(%{
        conversation_id: conv_id,
        kind: "stage",
        stage: stage,
        state: state,
        data: Jason.encode!(meta)
      })

    Phoenix.PubSub.broadcast(
      AgentOnDemand.PubSub,
      "conv:#{conv_id}",
      {:log_event, event}
    )
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
