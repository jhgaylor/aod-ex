defmodule AgentOnDemand.RuntimesTest do
  use ExUnit.Case, async: false
  use Mimic

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

    test ":run mode invokes codex exec with prompt as final argv + tty/no-stdin opts" do
      {"codex", args, opts} = Codex.build_command(nil, "hi there", :run, nil, [])
      assert "exec" in args
      assert "--dangerously-bypass-approvals-and-sandbox" in args
      assert "--json" in args
      assert ["--color", "never"] |> Enum.all?(&(&1 in args))
      refute "resume" in args
      assert List.last(args) == "hi there"
      # Skip the stdin pipe AND allocate a PTY so codex's isatty(0)
      # check is satisfied (kills the noisy startup banner).
      assert opts[:stdin?] == false
      assert opts[:tty?] == true
    end

    test ":continue mode adds resume --last and still trails the prompt" do
      {"codex", args, opts} = Codex.build_command(nil, "follow up", :continue, nil, [])
      assert ["exec", "resume", "--last" | _] = args
      assert List.last(args) == "follow up"
      assert opts[:stdin?] == false
      assert opts[:tty?] == true
    end
  end

  describe "Gemini.build_command/5" do
    alias AgentOnDemand.Runtimes.Gemini

    test ":run mode emits stream-json + yolo approval" do
      {"gemini", args, _} = Gemini.build_command(nil, "p", :run, nil, [])
      assert "stream-json" in args
      assert "--approval-mode" in args
      assert "yolo" in args
      refute "--resume" in args
    end

    test ":continue mode prepends --resume" do
      {"gemini", ["--resume" | rest], _} = Gemini.build_command(nil, "p", :continue, nil, [])
      assert "stream-json" in rest
    end

    test "passes --allowed-mcp-server-names when agent has mcp_servers" do
      agent = %{mcp_servers: %{"everything" => %{}, "time" => %{}}}
      {"gemini", args, _} = Gemini.build_command(agent, "p", :run, nil, [])
      assert "--allowed-mcp-server-names" in args
      # All server names must appear after the flag
      assert "everything" in args
      assert "time" in args
    end

    test "no --allowed-mcp-server-names flag when no MCP servers" do
      {"gemini", args, _} = Gemini.build_command(%{mcp_servers: %{}}, "p", :run, nil, [])
      refute "--allowed-mcp-server-names" in args
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

    # Every OpenCode.default_env return includes {"HOME", "/tmp"} so the
    # opencode CLI's storage root lands somewhere the sprite user can
    # actually access. See OpenCode.default_env/1 for context.
    test "anthropic/* → ANTHROPIC_API_KEY (+ HOME)" do
      assert OpenCode.default_env(%{model: "anthropic/claude-opus-4-6"}) ==
               [{"ANTHROPIC_API_KEY", "anth-x"}, {"HOME", "/tmp"}]
    end

    test "openai/* → OPENAI_API_KEY (+ HOME)" do
      assert OpenCode.default_env(%{model: "openai/gpt-4.1"}) ==
               [{"OPENAI_API_KEY", "oa-y"}, {"HOME", "/tmp"}]
    end

    test "google/* → GEMINI_API_KEY (+ HOME)" do
      assert OpenCode.default_env(%{model: "google/gemini-2.5-pro"}) ==
               [{"GEMINI_API_KEY", "g-z"}, {"HOME", "/tmp"}]
    end

    test "unknown provider returns just HOME" do
      assert OpenCode.default_env(%{model: "weirdco/model"}) == [{"HOME", "/tmp"}]
    end

    test "empty key returns just HOME" do
      Application.put_env(:agent_on_demand, :openai_api_key, "")
      assert OpenCode.default_env(%{model: "openai/gpt-4.1"}) == [{"HOME", "/tmp"}]
    end
  end

  describe "write_config/2 — MCP server config rendering" do
    alias AgentOnDemand.Runtimes.{Claude, Codex, Gemini, OpenCode}

    setup :set_mimic_global

    setup do
      Mimic.copy(Sprites)
      Mimic.copy(Sprites.Filesystem)
      stub(Sprites, :filesystem, fn _, _ -> :stub_fs end)
      stub(Sprites.Filesystem, :mkdir_p, fn _, _ -> :ok end)
      :ok
    end

    @mcp %{
      "time" => %{
        "command" => "npx",
        "args" => ["-y", "@modelcontextprotocol/server-time"],
        "env" => %{"TZ" => "UTC"}
      }
    }

    test "Claude writes ~/.claude.json with mcpServers" do
      test_pid = self()

      stub(Sprites.Filesystem, :write, fn _, path, payload ->
        send(test_pid, {:wrote, path, payload})
        :ok
      end)

      Claude.write_config(:sprite, %{mcp_servers: @mcp})
      assert_received {:wrote, "/home/sprite/.claude.json", payload}
      assert Jason.decode!(payload) == %{"mcpServers" => @mcp}
    end

    test "Codex writes ~/.codex/config.toml with [mcp_servers.<name>] blocks" do
      test_pid = self()

      stub(Sprites.Filesystem, :write, fn _, path, payload ->
        send(test_pid, {:wrote, path, payload})
        :ok
      end)

      Codex.write_config(:sprite, %{mcp_servers: @mcp})
      assert_received {:wrote, "/home/sprite/.codex/config.toml", toml}
      assert toml =~ "[mcp_servers.time]"
      assert toml =~ ~s(command = "npx")
      assert toml =~ ~s(args = ["-y", "@modelcontextprotocol/server-time"])
      assert toml =~ ~s(env = { TZ = "UTC" })
    end

    test "Gemini writes ~/.gemini/settings.json with mcpServers" do
      test_pid = self()

      stub(Sprites.Filesystem, :write, fn _, path, payload ->
        send(test_pid, {:wrote, path, payload})
        :ok
      end)

      Gemini.write_config(:sprite, %{mcp_servers: @mcp})
      assert_received {:wrote, "/home/sprite/.gemini/settings.json", payload}
      assert Jason.decode!(payload) == %{"mcpServers" => @mcp}
    end

    test "OpenCode writes opencode.json translated to mcp.<name> with type/command-array/environment" do
      test_pid = self()

      stub(Sprites.Filesystem, :write, fn _, path, payload ->
        send(test_pid, {:wrote, path, payload})
        :ok
      end)

      OpenCode.write_config(:sprite, %{mcp_servers: @mcp})

      # Writes to both /tmp/.config and /home/sprite/.config; capture
      # whichever comes through first and assert the schema shape.
      assert_received {:wrote, path, payload}
      assert path =~ "/.config/opencode/opencode.json"

      decoded = Jason.decode!(payload)
      assert decoded["$schema"] == "https://opencode.ai/config.json"

      assert decoded["mcp"]["time"] == %{
               "type" => "local",
               "command" => ["npx", "-y", "@modelcontextprotocol/server-time"],
               "environment" => %{"TZ" => "UTC"},
               "enabled" => true
             }
    end

    test "every runtime is a no-op when mcp_servers is empty / nil / agent is nil" do
      test_pid = self()

      stub(Sprites.Filesystem, :write, fn _, path, _ ->
        send(test_pid, {:unexpected_write, path})
        :ok
      end)

      for mod <- [Claude, Codex, Gemini, OpenCode] do
        assert :ok = mod.write_config(:sprite, nil)
        assert :ok = mod.write_config(:sprite, %{mcp_servers: %{}})
        assert :ok = mod.write_config(:sprite, %{mcp_servers: nil})
      end

      refute_received {:unexpected_write, _}
    end
  end
end
