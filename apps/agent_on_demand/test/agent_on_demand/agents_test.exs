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

  describe "list_agents/1 filtering" do
    test "returns all agents when called with empty keyword list" do
      a = insert_agent(%{})
      b = insert_agent(%{})
      ids = Agents.list_agents([]) |> Enum.map(& &1.id)
      assert a.id in ids
      assert b.id in ids
    end

    test "search filters by name substring — case-insensitive" do
      other = insert_agent(%{"name" => "zz-unrelated"})
      match = insert_agent(%{"name" => "My-Cool-Agent"})

      results = Agents.list_agents(search: "cool")
      assert Enum.any?(results, & &1.id == match.id)
      refute Enum.any?(results, & &1.id == other.id)
    end

    test "search returns all agents when search string is empty" do
      a = insert_agent(%{})
      results = Agents.list_agents(search: "")
      assert Enum.any?(results, & &1.id == a.id)
    end

    test "runtimes filter returns only agents with matching runtime" do
      claude = insert_agent(%{"runtime" => "claude"})
      codex = insert_agent(%{"runtime" => "codex"})

      results = Agents.list_agents(runtimes: ["claude"])
      assert Enum.any?(results, & &1.id == claude.id)
      refute Enum.any?(results, & &1.id == codex.id)
    end

    test "runtimes filter returns all agents when list is empty" do
      a = insert_agent(%{})
      results = Agents.list_agents(runtimes: [])
      assert Enum.any?(results, & &1.id == a.id)
    end

    test "env_ids 'none' filters to agents with no environment" do
      no_env = insert_agent(%{})
      env = insert_env()
      with_env = insert_agent(%{"environment_id" => env.id})

      results = Agents.list_agents(env_ids: ["none"])
      assert Enum.any?(results, & &1.id == no_env.id)
      refute Enum.any?(results, & &1.id == with_env.id)
    end

    test "env_ids with real id filters to agents with that environment" do
      env = insert_env()
      with_env = insert_agent(%{"environment_id" => env.id})
      no_env = insert_agent(%{})

      results = Agents.list_agents(env_ids: [env.id])
      assert Enum.any?(results, & &1.id == with_env.id)
      refute Enum.any?(results, & &1.id == no_env.id)
    end

    test "has_skills filters to agents with at least one skill" do
      with_skills =
        insert_agent(%{
          "skills" => [%{"name" => "test-skill", "content" => "# SKILL\nDoes stuff.\n"}]
        })

      bare = insert_agent(%{})

      results = Agents.list_agents(has_skills: true)
      assert Enum.any?(results, & &1.id == with_skills.id)
      refute Enum.any?(results, & &1.id == bare.id)
    end

    test "has_mcp filters to agents with at least one MCP server" do
      with_mcp =
        insert_agent(%{
          "mcp_servers" => %{"my_server" => %{"command" => "npx foo"}}
        })

      bare = insert_agent(%{})

      results = Agents.list_agents(has_mcp: true)
      assert Enum.any?(results, & &1.id == with_mcp.id)
      refute Enum.any?(results, & &1.id == bare.id)
    end
  end
end
