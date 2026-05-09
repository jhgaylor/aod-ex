defmodule AgentOnDemandWeb.ConversationControllerTest do
  use ExUnit.Case, async: true

  alias AgentOnDemandWeb.ConversationController

  describe "infer_provenance/1" do
    test "no header → source=api, parent=nil" do
      assert ConversationController.infer_provenance(nil) == {"api", nil}
    end

    test "empty header → source=api, parent=nil" do
      assert ConversationController.infer_provenance("") == {"api", nil}
    end

    test "non-empty header → source=agent, parent=that value" do
      uuid = "abcdef00-0000-0000-0000-000000000001"
      assert ConversationController.infer_provenance(uuid) == {"agent", uuid}
    end
  end
end
