defmodule AgentOnDemand.Agents.AgentTest do
  use AgentOnDemand.DataCase, async: false

  alias AgentOnDemand.Agents.Agent

  describe "changeset" do
    test "requires name, model, runtime" do
      cs = Agent.changeset(%Agent{}, %{})
      refute cs.valid?
      errors = errors_on(cs)
      assert errors[:name]
      assert errors[:model]
      assert errors[:runtime]
    end

    test "rejects non-canonical model string" do
      for bad <- ~w(claude no-slash bad/Model just/ /missing) do
        cs = Agent.changeset(%Agent{}, %{name: "x", model: bad, runtime: "claude"})
        refute cs.valid?, "expected #{bad} to be invalid"
      end
    end

    test "accepts canonical model strings" do
      for good <- [
            "anthropic/claude-sonnet-4-6",
            "anthropic/claude-opus-4-6",
            "openai/gpt-4.1",
            "google/gemini-2.5-pro"
          ] do
        cs = Agent.changeset(%Agent{}, %{name: "x", model: good, runtime: "claude"})
        assert cs.valid?, "expected #{good} to be valid; got #{inspect(errors_on(cs))}"
      end
    end

    test "rejects unknown runtime" do
      cs =
        Agent.changeset(%Agent{}, %{
          name: "x",
          model: "anthropic/claude-sonnet-4-6",
          runtime: "fake"
        })

      refute cs.valid?
    end

    test "accepts every documented runtime" do
      for r <- Agent.runtimes() do
        cs =
          Agent.changeset(%Agent{}, %{
            name: "x",
            model: "anthropic/claude-sonnet-4-6",
            runtime: r
          })

        assert cs.valid?, "runtime #{r} rejected"
      end
    end

    test "enforces unique name" do
      insert_agent(%{"name" => "alpha"})

      assert {:error, cs} =
               AgentOnDemand.Agents.create_agent(agent_attrs(%{"name" => "alpha"}))

      assert "has already been taken" in errors_on(cs).name
    end

    test "skills defaults to []" do
      a = insert_agent()
      assert a.skills == []
    end

    test "accepts inline skill entries" do
      cs =
        Agent.changeset(%Agent{}, %{
          name: "x",
          model: "anthropic/claude-sonnet-4-6",
          runtime: "claude",
          skills: [%{"name" => "house-style", "content" => "---\nname: house-style\n---\nbody"}]
        })

      assert cs.valid?, inspect(errors_on(cs))
    end

    test "accepts github skill entries" do
      cs =
        Agent.changeset(%Agent{}, %{
          name: "x",
          model: "anthropic/claude-sonnet-4-6",
          runtime: "claude",
          skills: [
            %{"source" => "anthropics/skills", "name" => "frontend-design"},
            %{"source" => "anthropics/skills"}
          ]
        })

      assert cs.valid?, inspect(errors_on(cs))
    end

    test "rejects skill entry with both content and source" do
      cs =
        Agent.changeset(%Agent{}, %{
          name: "x",
          model: "anthropic/claude-sonnet-4-6",
          runtime: "claude",
          skills: [%{"name" => "x", "content" => "...", "source" => "anthropics/skills"}]
        })

      refute cs.valid?
      assert errors_on(cs)[:skills]
    end

    test "rejects skill entry with neither content nor source" do
      cs =
        Agent.changeset(%Agent{}, %{
          name: "x",
          model: "anthropic/claude-sonnet-4-6",
          runtime: "claude",
          skills: [%{"name" => "x"}]
        })

      refute cs.valid?
      assert errors_on(cs)[:skills]
    end

    test "rejects inline skill entry without a name" do
      cs =
        Agent.changeset(%Agent{}, %{
          name: "x",
          model: "anthropic/claude-sonnet-4-6",
          runtime: "claude",
          skills: [%{"content" => "..."}]
        })

      refute cs.valid?
      assert errors_on(cs)[:skills]
    end

    test "preserves agent.metadata in upsert path" do
      a = insert_agent(%{"metadata" => %{"foo" => "bar"}})
      assert a.metadata == %{"foo" => "bar"}
    end
  end
end
