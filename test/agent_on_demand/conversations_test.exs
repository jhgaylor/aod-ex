defmodule AgentOnDemand.ConversationsTest do
  use AgentOnDemand.DataCase, async: false

  use Mimic

  alias AgentOnDemand.Conversations

  describe "sandbox CRUD" do
    test "create / update / get" do
      sb = insert_sandbox()
      assert sb.status == "pending"
      {:ok, sb} = Conversations.update_sandbox(sb, %{status: "ready"})
      assert sb.status == "ready"
      assert Conversations.get_sandbox(sb.id).id == sb.id
    end
  end

  describe "conversation CRUD" do
    test "list returns inserted convs with sandbox/agent preloaded" do
      sb1 = insert_sandbox(status: "ready")
      a = insert_agent()
      c1 = insert_conversation(sandbox: sb1, agent: a)
      sb2 = insert_sandbox(status: "ready")
      c2 = insert_conversation(sandbox: sb2, agent: a)

      ids = Conversations.list_conversations() |> Enum.map(& &1.id)
      assert c1.id in ids
      assert c2.id in ids

      head = Conversations.list_conversations() |> hd()
      assert head.sandbox.id in [sb1.id, sb2.id]
      assert head.agent.id == a.id
    end

    test "delete_conversation cascades turns and log events" do
      conv = insert_conversation()
      _t = insert_turn(conv)
      _e = insert_log_event(conv)

      {:ok, _} = Conversations.delete_conversation(conv)

      assert Conversations.get_conversation(conv.id) == nil
      assert Conversations.list_turns(conv.id) == []
      assert Conversations.list_log_events(conv.id) == []
    end
  end

  describe "turns" do
    test "next_turn_number increments per conversation" do
      a = insert_conversation()
      b = insert_conversation()
      assert Conversations.next_turn_number(a.id) == 1
      insert_turn(a, turn_number: 1)
      assert Conversations.next_turn_number(a.id) == 2
      assert Conversations.next_turn_number(b.id) == 1
    end

    test "list_turns is ordered by turn_number" do
      conv = insert_conversation()
      insert_turn(conv, turn_number: 1)
      insert_turn(conv, turn_number: 2)
      insert_turn(conv, turn_number: 3)
      assert [1, 2, 3] = Conversations.list_turns(conv.id) |> Enum.map(& &1.turn_number)
    end

    test "mark_orphaned_turns_interrupted only flips running turns" do
      conv = insert_conversation()
      t1 = insert_turn(conv, turn_number: 1, status: "completed")
      _t2 = insert_turn(conv, turn_number: 2, status: "running")
      _t3 = insert_turn(conv, turn_number: 3, status: "running")

      assert Conversations.mark_orphaned_turns_interrupted(conv.id) == 2

      [t1_after, t2_after, t3_after] = Conversations.list_turns(conv.id)
      assert t1_after.status == "completed"
      assert t2_after.status == "interrupted"
      assert t2_after.ended_at
      assert t3_after.status == "interrupted"
      # untouched conversation
      assert t1_after.id == t1.id
    end
  end

  describe "log events" do
    test "log! and list_log_events with cursor" do
      conv = insert_conversation()
      e1 = Conversations.log!(%{conversation_id: conv.id, kind: "output", data: "a"})
      e2 = Conversations.log!(%{conversation_id: conv.id, kind: "output", data: "b"})

      ids = Conversations.list_log_events(conv.id) |> Enum.map(& &1.id)
      assert ids == [e1.id, e2.id]

      # cursor returns only what's after
      after_e1 = Conversations.list_log_events(conv.id, e1.id) |> Enum.map(& &1.id)
      assert after_e1 == [e2.id]
    end
  end

  describe "list_resumable_conversations" do
    test "returns idle/running with ready sandbox; excludes others" do
      ok_idle = insert_conversation(sandbox: insert_sandbox(status: "ready"), status: "idle")
      ok_running = insert_conversation(sandbox: insert_sandbox(status: "ready"), status: "running")

      _terminated =
        insert_conversation(sandbox: insert_sandbox(status: "terminated"), status: "terminated")

      _failed = insert_conversation(sandbox: insert_sandbox(status: "failed"), status: "failed")
      _pending_sb = insert_conversation(sandbox: insert_sandbox(status: "pending"), status: "idle")

      ids = Conversations.list_resumable_conversations() |> Enum.map(& &1.id)
      assert ok_idle.id in ids
      assert ok_running.id in ids
      assert length(ids) == 2
    end
  end

  describe "wake_conversation" do
    setup :set_mimic_global
    setup :verify_on_exit!

    setup do
      env = insert_env()
      agent = insert_agent(%{"environment_id" => env.id})
      old_sandbox = insert_sandbox(status: "ready", sprite_name: "old-sprite")

      conv =
        insert_conversation(
          sandbox: old_sandbox,
          agent: agent,
          status: "idle"
        )
        |> Repo.preload(:sandbox)

      {:ok, agent: agent, conv: conv, old_sandbox: old_sandbox}
    end

    test "rejects terminated/failed/completed conversations", %{conv: conv} do
      {:ok, conv} = Conversations.update_conversation(conv, %{status: "terminated"})
      assert {:error, :gone} = Conversations.wake_conversation(conv.id, "p")
    end

    test "reuses sandbox when sprite is alive", %{conv: conv, old_sandbox: old_sandbox} do
      stub(AgentOnDemand.SpritesClient, :get!, fn -> :stub_client end)
      stub(Sprites, :get_sprite, fn :stub_client, "old-sprite" -> {:ok, %{}} end)
      stub_dyn_supervisor()

      assert {:ok, woken} = Conversations.wake_conversation(conv.id, nil)
      assert woken.sandbox_id == old_sandbox.id
    end

    test "creates new sandbox when sprite is gone", %{conv: conv, old_sandbox: old_sandbox} do
      stub(AgentOnDemand.SpritesClient, :get!, fn -> :stub_client end)
      stub(Sprites, :get_sprite, fn :stub_client, "old-sprite" -> {:error, :not_found} end)
      stub_dyn_supervisor()

      assert {:ok, woken} = Conversations.wake_conversation(conv.id, nil)
      refute woken.sandbox_id == old_sandbox.id

      old = Conversations.get_sandbox(old_sandbox.id)
      assert old.status == "terminated"
    end

    # Don't actually start a ConversationServer — its handle_continue would
    # query the sandbox on a separate process that can't see our Ecto
    # sandbox, plus it would try to talk to sprites.dev. Verifying the
    # *call* is enough; the ConversationServer's own behavior is tested
    # in conversation_server_test.exs.
    defp stub_dyn_supervisor do
      stub(Horde.DynamicSupervisor, :start_child, fn AgentOnDemand.ConversationSupervisor, _spec ->
        {:ok, self()}
      end)
    end
  end
end
