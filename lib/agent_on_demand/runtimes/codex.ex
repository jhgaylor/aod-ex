defmodule AgentOnDemand.Runtimes.Codex do
  @moduledoc """
  OpenAI Codex CLI runtime.

  Argv shape (mirrors AoD's `build_codex_command`):

      mode == :run       → codex exec
                              --dangerously-bypass-approvals-and-sandbox
                              --json
      mode == :continue  → codex exec resume --last
                              --dangerously-bypass-approvals-and-sandbox
                              --json

  Codex tracks its own per-workspace conversation state on disk, so we
  pass no session id; `--last` (in `continue` mode) tells it to reattach
  to the most recent conversation in the workspace. `--json` is the
  line-delimited stream-json output the worker tails into LogEvents.

  Auth: `OPENAI_API_KEY` exported into the sprite.
  """

  @behaviour AgentOnDemand.Runtimes

  @impl true
  def build_command(_agent, _prompt, mode, _runtime_session_id, _opts) do
    args =
      if mode == :continue do
        [
          "exec",
          "resume",
          "--last",
          "--dangerously-bypass-approvals-and-sandbox",
          "--json"
        ]
      else
        [
          "exec",
          "--dangerously-bypass-approvals-and-sandbox",
          "--json"
        ]
      end

    {"codex", args, []}
  end

  @impl true
  def default_env(_agent) do
    case Application.get_env(:agent_on_demand, :openai_api_key) do
      nil -> []
      "" -> []
      key -> [{"OPENAI_API_KEY", key}]
    end
  end
end
