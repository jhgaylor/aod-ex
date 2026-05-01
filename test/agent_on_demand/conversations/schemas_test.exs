defmodule AgentOnDemand.Conversations.SchemasTest do
  use AgentOnDemand.DataCase, async: true

  alias AgentOnDemand.Conversations.{Conversation, LogEvent, Sandbox, Turn}
  alias AgentOnDemand.Repo

  describe "Sandbox.changeset" do
    test "requires sprite_name (status has a default)" do
      cs = Sandbox.changeset(%Sandbox{}, %{})
      refute cs.valid?
      errors = errors_on(cs)
      assert errors[:sprite_name]
    end

    test "rejects unknown status" do
      cs = Sandbox.changeset(%Sandbox{}, %{sprite_name: "x", status: "in-flight"})
      refute cs.valid?
    end

    test "accepts every documented status" do
      for s <- Sandbox.statuses() do
        cs = Sandbox.changeset(%Sandbox{}, %{sprite_name: "x", status: s})
        assert cs.valid?, "status #{s} rejected"
      end
    end
  end

  describe "Conversation.changeset" do
    setup do
      {:ok, sandbox: insert_sandbox()}
    end

    test "requires runtime + sandbox_id (status has a default)", %{sandbox: _sb} do
      cs = Conversation.changeset(%Conversation{}, %{})
      refute cs.valid?
      errors = errors_on(cs)
      assert errors[:runtime]
      assert errors[:sandbox_id]
    end

    test "accepts each valid status", %{sandbox: sb} do
      for s <- Conversation.statuses() do
        cs =
          Conversation.changeset(%Conversation{}, %{
            sandbox_id: sb.id,
            runtime: "claude",
            status: s
          })

        assert cs.valid?, "status #{s} rejected"
      end
    end

    test "rejects unknown status", %{sandbox: sb} do
      cs =
        Conversation.changeset(%Conversation{}, %{
          sandbox_id: sb.id,
          runtime: "claude",
          status: "talking"
        })

      refute cs.valid?
    end
  end

  describe "Turn.changeset" do
    setup do
      {:ok, conv: insert_conversation()}
    end

    test "requires turn_number, prompt, status, conversation_id", %{conv: _conv} do
      cs = Turn.changeset(%Turn{}, %{})
      refute cs.valid?
      errors = errors_on(cs)
      assert errors[:turn_number]
      assert errors[:prompt]
    end

    test "rejects unknown status", %{conv: conv} do
      cs =
        Turn.changeset(%Turn{}, %{
          conversation_id: conv.id,
          turn_number: 1,
          prompt: "p",
          status: "thinking"
        })

      refute cs.valid?
    end

    test "interrupted is a valid status", %{conv: conv} do
      cs =
        Turn.changeset(%Turn{}, %{
          conversation_id: conv.id,
          turn_number: 1,
          prompt: "p",
          status: "interrupted"
        })

      assert cs.valid?
    end

    test "(conversation_id, turn_number) is unique", %{conv: conv} do
      insert_turn(conv, turn_number: 1)
      cs = Turn.changeset(%Turn{}, %{conversation_id: conv.id, turn_number: 1, prompt: "p", status: "pending"})
      assert {:error, _} = Repo.insert(cs)
    end
  end

  describe "LogEvent.changeset" do
    setup do
      {:ok, conv: insert_conversation()}
    end

    test "requires kind, conversation_id, inserted_at", %{conv: _conv} do
      cs = LogEvent.changeset(%LogEvent{}, %{})
      refute cs.valid?
    end

    test "kind must be in ['output', 'stage']", %{conv: conv} do
      cs =
        LogEvent.changeset(%LogEvent{}, %{
          conversation_id: conv.id,
          kind: "weird",
          inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      refute cs.valid?
    end

    test "stream defaults to '' and is optional", %{conv: conv} do
      cs =
        LogEvent.changeset(%LogEvent{}, %{
          conversation_id: conv.id,
          kind: "stage",
          stage: "provision",
          state: "started",
          inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      assert cs.valid?
    end

    test "interrupted is a valid stage state", %{conv: conv} do
      cs =
        LogEvent.changeset(%LogEvent{}, %{
          conversation_id: conv.id,
          kind: "stage",
          stage: "turn",
          state: "interrupted",
          inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      assert cs.valid?
    end
  end
end
