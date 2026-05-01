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

  @doc """
  Optionally run any sprite-side bootstrap that has to happen *before*
  the first turn — e.g. codex needs `codex login --with-api-key` to
  persist credentials into `~/.codex/auth.json` since it doesn't read
  `OPENAI_API_KEY` from the live process env.

  Receives the same `sprite_env` pairs the spawn will use. Implementers
  pull whichever keys they need out of that list. No-op by default.
  """
  @callback prepare_sprite(
              sprite :: any(),
              agent :: %Agent{} | nil,
              sprite_env :: [{String.t(), String.t()}]
            ) :: :ok | {:error, term()}

  @doc """
  Optionally return a list of substring patterns that identify
  uninteresting stderr lines emitted by the runtime CLI (startup
  banners, MCP refresh chatter, etc.). Any stderr line *containing*
  one of these substrings is dropped before being persisted as a
  log event. No-op by default.

  Real errors won't match — gemini-cli prints things like "Failed to
  generate content..." which we want to keep — so this is a
  best-effort prettifier, not a security boundary.
  """
  @callback stderr_noise_patterns() :: [String.t()]

  @optional_callbacks default_env: 1,
                      write_config: 2,
                      prepare_sprite: 3,
                      stderr_noise_patterns: 0

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
