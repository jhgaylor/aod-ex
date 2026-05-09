defmodule AgentOnDemand.Conversations.ConversationTest do
  use AgentOnDemand.DataCase, async: true

  alias AgentOnDemand.Conversations.Conversation

  # Changeset validates :runtime, :status, :sandbox_id. The schema defaults
  # :status to "pending", so a sandbox_id is the only thing the test
  # fixture needs to add. The UUID doesn't need to exist in the DB —
  # validate_required only checks presence.
  @valid_attrs %{
    "prompt" => "hello",
    "runtime" => "claude",
    "sandbox_id" => "11111111-1111-1111-1111-111111111111"
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

  alias AgentOnDemand.Conversations
  alias AgentOnDemand.Repo

  describe "get_conversation_tree/1" do
    defp make_sandbox do
      {:ok, sandbox} = Conversations.create_sandbox(%{sprite_name: "test-#{System.unique_integer()}", status: "pending"})
      sandbox
    end

    defp make_conv(sandbox_id, attrs \\ %{}) do
      %Conversation{}
      |> Conversation.changeset(Map.merge(%{
        sandbox_id: sandbox_id,
        runtime: "claude",
        status: "pending",
        source: "api"
      }, attrs))
      |> Repo.insert!()
    end

    test "returns a single node when conversation has no parent or children" do
      sb = make_sandbox()
      root = make_conv(sb.id, %{source: "ui"})

      tree = Conversations.get_conversation_tree(root.id)

      assert length(tree) == 1
      [node] = tree
      assert node.id == root.id
      assert node.source == "ui"
      assert is_nil(node.parent_id)
    end

    test "returns all descendants when called from root" do
      sb = make_sandbox()
      root = make_conv(sb.id, %{source: "ui"})
      child = make_conv(sb.id, %{source: "agent", parent_conversation_id: root.id})
      _grandchild = make_conv(sb.id, %{source: "agent", parent_conversation_id: child.id})

      tree = Conversations.get_conversation_tree(root.id)
      ids = Enum.map(tree, & &1.id)

      assert length(tree) == 3
      assert root.id in ids
      assert child.id in ids
    end

    test "walks up to root and returns full tree when called from a child node" do
      sb = make_sandbox()
      root = make_conv(sb.id, %{source: "ui"})
      child = make_conv(sb.id, %{source: "agent", parent_conversation_id: root.id})
      grandchild = make_conv(sb.id, %{source: "agent", parent_conversation_id: child.id})

      # Call from grandchild — should still get all 3 nodes
      tree = Conversations.get_conversation_tree(grandchild.id)
      ids = Enum.map(tree, & &1.id)

      assert length(tree) == 3
      assert root.id in ids
      assert child.id in ids
      assert grandchild.id in ids
    end

    test "each node map has expected keys" do
      sb = make_sandbox()
      root = make_conv(sb.id)

      [node] = Conversations.get_conversation_tree(root.id)

      assert Map.has_key?(node, :id)
      assert Map.has_key?(node, :source)
      assert Map.has_key?(node, :status)
      assert Map.has_key?(node, :parent_id)
      assert Map.has_key?(node, :inserted_at)
    end
  end
end
