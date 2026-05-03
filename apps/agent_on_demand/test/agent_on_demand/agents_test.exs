defmodule AgentOnDemand.AgentsTest do
  use AgentOnDemand.DataCase, async: false

  alias AgentOnDemand.Agents

  describe "agents CRUD" do
    test "list_agents preloads environment" do
      env = insert_env()
      _a = insert_agent(%{"name" => "x", "environment_id" => env.id})
      [agent | _] = Agents.list_agents()
      assert agent.environment.id == env.id
    end

    test "get_agent preloads environment" do
      env = insert_env()
      a = insert_agent(%{"name" => "y", "environment_id" => env.id})
      got = Agents.get_agent(a.id)
      assert got.environment.id == env.id
    end

    test "create then update" do
      a = insert_agent(%{"name" => "before"})
      {:ok, a} = Agents.update_agent(a, %{"system" => "you are a helper"})
      assert a.system == "you are a helper"
    end

    test "delete removes the row" do
      a = insert_agent()
      {:ok, _} = Agents.delete_agent(a)
      assert Agents.get_agent(a.id) == nil
    end

    # SQLite doesn't surface enough info on FK violations for Ecto to map
    # them back to a named constraint, so passing an invalid environment_id
    # raises rather than returning a changeset error. That's a programmer
    # mistake (the API never accepts arbitrary uuids — it goes through
    # validation), so we accept this trade-off.
    test "create with non-existent environment_id raises" do
      assert_raise Ecto.ConstraintError, fn ->
        Agents.create_agent(agent_attrs(%{"environment_id" => Ecto.UUID.generate()}))
      end
    end
  end
end
