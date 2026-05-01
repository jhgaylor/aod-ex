defmodule AgentOnDemand.Runtimes.Gemini do
  @moduledoc """
  Google Gemini CLI runtime.

  Argv shape:

      mode == :run       → gemini --output-format stream-json
      mode == :continue  → gemini --resume --output-format stream-json

  Gemini manages its own session state — `--resume` re-enters the most
  recent conversation in the workspace, so we don't pass a session id.
  `--output-format stream-json` is the line-delimited stream the worker
  tails.

  Auth: `GEMINI_API_KEY` exported into the sprite.
  """

  @behaviour AgentOnDemand.Runtimes

  @impl true
  def build_command(_agent, _prompt, mode, _runtime_session_id, _opts) do
    args =
      if mode == :continue do
        ["--resume", "--output-format", "stream-json"]
      else
        ["--output-format", "stream-json"]
      end

    {"gemini", args, []}
  end

  @impl true
  def default_env(_agent) do
    case Application.get_env(:agent_on_demand, :gemini_api_key) do
      nil -> []
      "" -> []
      key -> [{"GEMINI_API_KEY", key}]
    end
  end
end
