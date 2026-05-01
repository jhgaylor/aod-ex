defmodule AgentOnDemand.Runtimes do
  @moduledoc """
  Behaviour every runtime (claude/codex/gemini/opencode) implements,
  plus a small dispatcher.
  """

  alias AgentOnDemand.Agents.Agent

  @type mode :: :run | :continue
  @type cmd :: {String.t(), [String.t()], keyword()}

  @doc """
  Build the argv (and any extra spawn opts like `:env`) for a single turn.

  - `mode == :run` for the first turn
  - `mode == :continue` for subsequent turns
  - `runtime_session_id` is the runtime CLI's own session id used for resume
  """
  @callback build_command(
              agent :: %Agent{},
              prompt :: String.t(),
              mode :: mode(),
              runtime_session_id :: String.t() | nil,
              opts :: keyword()
            ) :: cmd()

  @doc "Default env vars for the runtime (e.g. ANTHROPIC_API_KEY)."
  @callback default_env(agent :: %Agent{}) :: [{String.t(), String.t()}]

  @doc """
  Optionally write runtime-specific config files into the sprite at
  provision time (e.g. claude's `~/.claude.json` for MCP servers).
  No-op by default.
  """
  @callback write_config(sprite :: any(), agent :: %Agent{} | nil) :: :ok

  @optional_callbacks default_env: 1, write_config: 2

  @runtime_modules %{
    "claude" => AgentOnDemand.Runtimes.Claude,
    "codex" => AgentOnDemand.Runtimes.Codex,
    "gemini" => AgentOnDemand.Runtimes.Gemini,
    "opencode" => AgentOnDemand.Runtimes.OpenCode
  }

  @doc "Look up the runtime module for an agent's runtime string."
  def for_runtime(name) when is_binary(name) do
    case Map.fetch(@runtime_modules, name) do
      {:ok, mod} -> {:ok, mod}
      :error -> {:error, "unsupported runtime: #{name}"}
    end
  end
end
