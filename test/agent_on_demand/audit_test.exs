defmodule AgentOnDemand.AuditTest do
  use AgentOnDemand.DataCase, async: false

  alias AgentOnDemand.Audit

  describe "record/1" do
    test "inserts an event with sane defaults" do
      assert {:ok, event} =
               Audit.record(%{
                 action: "POST /api/conversations",
                 resource_type: "conversation",
                 resource_id: "abc",
                 actor: "api"
               })

      assert event.id
      assert event.metadata == %{}
      assert event.inserted_at
    end

    test "{:error, _} on invalid attrs (missing required)" do
      assert {:error, _cs} = Audit.record(%{action: "x"})
    end
  end

  describe "list_recent/1" do
    test "returns newest first" do
      Audit.record!(%{action: "first", resource_type: "x"})
      Audit.record!(%{action: "second", resource_type: "x"})
      Audit.record!(%{action: "third", resource_type: "x"})

      assert ["third", "second", "first"] =
               Audit.list_recent(10) |> Enum.map(& &1.action)
    end

    test "respects limit" do
      for i <- 1..5, do: Audit.record!(%{action: "n#{i}", resource_type: "x"})
      assert length(Audit.list_recent(2)) == 2
    end
  end

  describe "list_for/2" do
    test "filters by resource" do
      Audit.record!(%{action: "create", resource_type: "agent", resource_id: "a"})
      Audit.record!(%{action: "delete", resource_type: "agent", resource_id: "a"})
      Audit.record!(%{action: "create", resource_type: "agent", resource_id: "b"})

      events = Audit.list_for("agent", "a")
      assert length(events) == 2
      assert Enum.all?(events, &(&1.resource_id == "a"))
    end
  end
end
