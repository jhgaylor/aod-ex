defmodule AgentOnDemand.Conversations.ConversationServerTest do
  use AgentOnDemand.DataCase, async: false
  use Mimic

  alias AgentOnDemand.Conversations
  alias AgentOnDemand.Conversations.{ConversationServer, Sandbox, Turn}
  alias AgentOnDemand.Repo

  setup :set_mimic_global

  setup do
    # Default-stub everything ConversationServer touches on the sprites
    # SDK so a forgotten stub raises a clear "unexpected call" rather
    # than hitting the real API.
    stub(AgentOnDemand.SpritesClient, :get!, fn -> :stub_client end)
    stub(Sprites, :create, fn :stub_client, _name -> {:ok, :stub_sprite} end)
    stub(Sprites, :sprite, fn :stub_client, _name -> :stub_sprite end)
    stub(Sprites, :get_sprite, fn :stub_client, _name -> {:ok, %{}} end)
    stub(Sprites, :destroy, fn _ -> :ok end)
    stub(Sprites, :update_network_policy, fn _, _ -> :ok end)
    stub(Sprites, :list_sessions, fn _ -> {:ok, []} end)
    stub(Sprites, :filesystem, fn _, _ -> %{} end)
    stub(Sprites.Filesystem, :write, fn _, _, _ -> :ok end)
    stub(Sprites.Filesystem, :mkdir_p, fn _, _ -> :ok end)
    stub(Sprites, :cmd, fn _sprite, _cmd, _args, _opts -> {"", 0} end)

    env = insert_env()
    agent = insert_agent(%{"environment_id" => env.id})

    {:ok, env: env, agent: agent}
  end

  describe "fresh provision happy path" do
    test "transitions sandbox: pending -> starting -> ready", %{agent: agent} do
      sb = insert_sandbox(status: "pending")
      conv = insert_conversation(sandbox: sb, agent: agent, status: "pending")

      # GenServer accesses the sandbox via Repo from a separate process
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      pid = start_server!(conv.id, sb.id)
      wait_for_status(sb.id, "ready")

      sb_after = Conversations.get_sandbox(sb.id)
      assert sb_after.status == "ready"

      stop_server(pid)
    end
  end

  describe "fresh provision failure paths" do
    test "sprite create error → sandbox failed, server stops", %{agent: agent} do
      stub(Sprites, :create, fn _, _ -> {:error, :sprite_quota_exceeded} end)

      sb = insert_sandbox(status: "pending")
      conv = insert_conversation(sandbox: sb, agent: agent, status: "pending")

      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      pid = start_server!(conv.id, sb.id)
      ref = Process.monitor(pid)

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000

      sb_after = Conversations.get_sandbox(sb.id)
      assert sb_after.status == "failed"
      conv_after = Conversations.get_conversation(conv.id)
      assert conv_after.status == "failed"
    end

    test "setup_script non-zero exit → provision failed, sprite destroyed", %{agent: agent, env: env} do
      {:ok, _} =
        AgentOnDemand.Environments.update_environment(env, %{
          "setup_script" => "false"
        })

      # Setup script call returns non-zero; everything else (chmod, etc.) is fine.
      stub(Sprites, :cmd, fn _sprite, _exe, args, _opts ->
        if "false" in (args || []), do: {"oops", 1}, else: {"", 0}
      end)

      destroyed = self()
      stub(Sprites, :destroy, fn _sprite -> send(destroyed, :destroyed); :ok end)

      sb = insert_sandbox(status: "pending")
      conv = insert_conversation(sandbox: sb, agent: agent, status: "pending")

      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      pid = start_server!(conv.id, sb.id)
      ref = Process.monitor(pid)

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000
      assert_received :destroyed

      sb_after = Conversations.get_sandbox(sb.id)
      assert sb_after.status == "failed"
    end
  end

  describe "reattach mode" do
    test "ready sandbox → enters reattach, server stays alive", %{agent: agent} do
      sb = insert_sandbox(status: "ready", sprite_name: "live-sprite")
      conv = insert_conversation(sandbox: sb, agent: agent, status: "idle")

      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      pid = start_server!(conv.id, sb.id)

      # Server should stay alive (no provision step since sandbox is ready)
      ref = Process.monitor(pid)
      refute_receive {:DOWN, ^ref, :process, ^pid, _}, 200

      stop_server(pid)
    end

    test "ready sandbox + dead sprite → marks sandbox failed, server stops", %{agent: agent} do
      stub(Sprites, :get_sprite, fn _, _ -> {:error, :not_found} end)

      sb = insert_sandbox(status: "ready", sprite_name: "ghost")
      conv = insert_conversation(sandbox: sb, agent: agent, status: "idle")

      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      pid = start_server!(conv.id, sb.id)
      ref = Process.monitor(pid)

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000

      sb_after = Conversations.get_sandbox(sb.id)
      assert sb_after.status == "failed"
    end

    test "ready sandbox + running turn + active session → reattaches to session",
         %{agent: agent} do
      stub(Sprites, :list_sessions, fn _ ->
        {:ok, [%Sprites.Session{id: "live-session", is_active: true}]}
      end)

      command_pid = self()

      stub(Sprites, :attach_session, fn _, "live-session", _opts ->
        {:ok, %Sprites.Command{ref: make_ref(), pid: command_pid}}
      end)

      sb = insert_sandbox(status: "ready", sprite_name: "alive")
      conv = insert_conversation(sandbox: sb, agent: agent, status: "running")
      _running_turn = insert_turn(conv, turn_number: 1, status: "running")

      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      pid = start_server!(conv.id, sb.id)
      Process.sleep(200)

      assert Process.alive?(pid)
      # Reattach flipped conv to running
      assert Conversations.get_conversation(conv.id).status == "running"

      stop_server(pid)
    end

    test "ready sandbox + running turn + no active session → marks turn interrupted",
         %{agent: agent} do
      stub(Sprites, :list_sessions, fn _ -> {:ok, []} end)

      sb = insert_sandbox(status: "ready", sprite_name: "alive")
      conv = insert_conversation(sandbox: sb, agent: agent, status: "running")
      running_turn = insert_turn(conv, turn_number: 1, status: "running")

      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      pid = start_server!(conv.id, sb.id)
      Process.sleep(200)

      turn_after = Repo.get!(Turn, running_turn.id)
      assert turn_after.status == "interrupted"
      assert turn_after.ended_at

      stop_server(pid)
    end
  end

  describe "send_prompt + interrupt + terminate via API" do
    test "send_prompt on idle conversation with no GenServer → wakes via wake_conversation",
         %{agent: agent} do
      sb = insert_sandbox(status: "ready", sprite_name: "exists")
      conv = insert_conversation(sandbox: sb, agent: agent, status: "idle")

      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      stub(Horde.DynamicSupervisor, :start_child, fn _sup, _spec ->
        {:ok, self()}
      end)

      assert :ok = ConversationServer.send_prompt(conv.id, "test prompt")
    end

    test "terminate on conversation without GenServer marks DB rows" do
      sb = insert_sandbox(status: "ready")
      conv = insert_conversation(sandbox: sb, status: "idle")

      assert :ok = ConversationServer.terminate(conv.id)

      assert Conversations.get_conversation(conv.id).status == "terminated"
      assert Conversations.get_sandbox(sb.id).status == "terminated"
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp start_server!(conv_id, sb_id) do
    {:ok, pid} =
      ConversationServer.start_link(
        conversation_id: conv_id,
        sandbox_id: sb_id,
        runtime_module: AgentOnDemand.Runtimes.Claude,
        initial_prompt: nil
      )

    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)
    pid
  end

  defp stop_server(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      ref = Process.monitor(pid)
      GenServer.stop(pid, :normal, 1_000)
      receive do
        {:DOWN, ^ref, :process, ^pid, _} -> :ok
      after
        1_000 -> :ok
      end
    end
  end

  defp wait_for_status(sandbox_id, target_status, deadline_ms \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms

    Stream.unfold(:loop, fn :loop ->
      sb = Conversations.get_sandbox(sandbox_id)

      cond do
        sb && sb.status == target_status ->
          nil

        System.monotonic_time(:millisecond) > deadline ->
          flunk("expected sandbox #{sandbox_id} to reach #{target_status}, got #{inspect(sb && sb.status)}")

        true ->
          Process.sleep(20)
          {:loop, :loop}
      end
    end)
    |> Enum.to_list()
  end
end
