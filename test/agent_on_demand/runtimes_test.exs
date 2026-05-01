defmodule AgentOnDemand.RuntimesTest do
  use ExUnit.Case, async: false

  alias AgentOnDemand.Runtimes

  describe "for_runtime/1" do
    test "every documented runtime has a module" do
      for r <- ~w(claude codex gemini opencode) do
        assert {:ok, mod} = Runtimes.for_runtime(r)
        assert is_atom(mod)
        assert Code.ensure_loaded?(mod)
      end
    end

    test "rejects unknown runtimes" do
      assert {:error, _} = Runtimes.for_runtime("typescript-please")
    end
  end

  describe "Claude.build_command/5" do
    alias AgentOnDemand.Runtimes.Claude

    test ":run mode uses --session-id with the supplied id" do
      {"claude", args, _} = Claude.build_command(nil, "p", :run, "abc-123", [])
      assert "--session-id" in args
      assert "abc-123" in args
      refute "--resume" in args
    end

    test ":continue mode uses --resume" do
      {"claude", args, _} = Claude.build_command(nil, "p", :continue, "abc-123", [])
      assert "--resume" in args
      assert "abc-123" in args
      refute "--session-id" in args
    end

    test "stream-json output format is always present" do
      for mode <- [:run, :continue] do
        {"claude", args, _} = Claude.build_command(nil, "p", mode, "id-1", [])
        assert "stream-json" in args
        assert "--print" in args
        assert "--verbose" in args
      end
    end
  end

  describe "Codex.build_command/5" do
    alias AgentOnDemand.Runtimes.Codex

    test ":run mode invokes codex exec" do
      assert {"codex", ["exec" | rest], _} = Codex.build_command(nil, "p", :run, nil, [])
      assert "--dangerously-bypass-approvals-and-sandbox" in rest
      assert "--json" in rest
      refute "resume" in rest
    end

    test ":continue mode adds resume --last in correct position" do
      assert {"codex", ["exec", "resume", "--last" | _], _} =
               Codex.build_command(nil, "p", :continue, nil, [])
    end
  end

  describe "Gemini.build_command/5" do
    alias AgentOnDemand.Runtimes.Gemini

    test ":run mode" do
      assert {"gemini", ["--output-format", "stream-json"], _} =
               Gemini.build_command(nil, "p", :run, nil, [])
    end

    test ":continue mode adds --resume first" do
      assert {"gemini", ["--resume" | rest], _} =
               Gemini.build_command(nil, "p", :continue, nil, [])

      assert "stream-json" in rest
    end
  end

  describe "OpenCode.build_command/5" do
    alias AgentOnDemand.Runtimes.OpenCode

    test "inlines model into argv" do
      agent = %{model: "anthropic/claude-sonnet-4-6"}

      assert {"opencode", ["run", "--model", "anthropic/claude-sonnet-4-6" | rest], _} =
               OpenCode.build_command(agent, "p", :run, nil, [])

      assert "--format" in rest
      assert "json" in rest
      refute "--continue" in rest
    end

    test ":continue mode appends --continue" do
      agent = %{model: "openai/gpt-4.1"}
      {"opencode", args, _} = OpenCode.build_command(agent, "p", :continue, nil, [])
      assert List.last(args) == "--continue"
    end
  end

  describe "OpenCode.default_env/1 picks the right key per provider" do
    alias AgentOnDemand.Runtimes.OpenCode

    setup do
      # Don't leak the host's real keys into other tests; restore on exit.
      old = %{
        anthropic: Application.get_env(:agent_on_demand, :anthropic_api_key),
        openai: Application.get_env(:agent_on_demand, :openai_api_key),
        gemini: Application.get_env(:agent_on_demand, :gemini_api_key)
      }

      Application.put_env(:agent_on_demand, :anthropic_api_key, "anth-x")
      Application.put_env(:agent_on_demand, :openai_api_key, "oa-y")
      Application.put_env(:agent_on_demand, :gemini_api_key, "g-z")

      on_exit(fn ->
        Application.put_env(:agent_on_demand, :anthropic_api_key, old.anthropic)
        Application.put_env(:agent_on_demand, :openai_api_key, old.openai)
        Application.put_env(:agent_on_demand, :gemini_api_key, old.gemini)
      end)

      :ok
    end

    test "anthropic/* → ANTHROPIC_API_KEY" do
      assert OpenCode.default_env(%{model: "anthropic/claude-opus-4-6"}) ==
               [{"ANTHROPIC_API_KEY", "anth-x"}]
    end

    test "openai/* → OPENAI_API_KEY" do
      assert OpenCode.default_env(%{model: "openai/gpt-4.1"}) ==
               [{"OPENAI_API_KEY", "oa-y"}]
    end

    test "google/* → GEMINI_API_KEY" do
      assert OpenCode.default_env(%{model: "google/gemini-2.5-pro"}) ==
               [{"GEMINI_API_KEY", "g-z"}]
    end

    test "unknown provider returns []" do
      assert OpenCode.default_env(%{model: "weirdco/model"}) == []
    end

    test "empty key returns []" do
      Application.put_env(:agent_on_demand, :openai_api_key, "")
      assert OpenCode.default_env(%{model: "openai/gpt-4.1"}) == []
    end
  end
end
