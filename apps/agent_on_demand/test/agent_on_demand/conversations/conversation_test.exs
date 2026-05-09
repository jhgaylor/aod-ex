defmodule AgentOnDemand.Conversations.ConversationTest do
  use AgentOnDemand.DataCase, async: true

  alias AgentOnDemand.Conversations.Conversation

  @valid_attrs %{
    "prompt" => "hello",
    "runtime" => "claude"
  }

  describe "changeset/2 — source" do
    test "defaults to api when source is omitted" do
      changeset = Conversation.changeset(%Conversation{}, @valid_attrs)
      assert changeset.valid?
      assert get_field(changeset, :source) == "api"
    end

    test "accepts ui as a valid source" do
      changeset = Conversation.changeset(%Conversation{}, Map.put(@valid_attrs, "source", "ui"))
      assert changeset.valid?
      assert get_field(changeset, :source) == "ui"
    end

    test "accepts agent as a valid source" do
      changeset = Conversation.changeset(%Conversation{}, Map.put(@valid_attrs, "source", "agent"))
      assert changeset.valid?
      assert get_field(changeset, :source) == "agent"
    end

    test "rejects unknown source values" do
      changeset = Conversation.changeset(%Conversation{}, Map.put(@valid_attrs, "source", "webhook"))
      refute changeset.valid?
      assert errors_on(changeset)[:source]
    end
  end

  describe "changeset/2 — parent_conversation_id" do
    test "is nil by default" do
      changeset = Conversation.changeset(%Conversation{}, @valid_attrs)
      assert get_field(changeset, :parent_conversation_id) == nil
    end

    test "accepts a valid UUID" do
      parent_id = Ecto.UUID.generate()
      attrs = Map.put(@valid_attrs, "parent_conversation_id", parent_id)
      changeset = Conversation.changeset(%Conversation{}, attrs)
      assert changeset.valid?
      assert get_field(changeset, :parent_conversation_id) == parent_id
    end
  end
end
