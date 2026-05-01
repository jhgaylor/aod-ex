defmodule AgentOnDemand.Runtimes.OpenCode do
  @moduledoc """
  Opencode CLI runtime — a multi-provider front-end. Unlike claude /
  codex / gemini whose argv is model-agnostic, opencode inlines the
  model into argv via `--model provider/model_id`.

  Argv shape:

      mode == :run       → opencode run --model <agent.model> --format json
      mode == :continue  → opencode run --model <agent.model> --format json --continue

  Auth: depends on the provider in `agent.model`. We export whichever
  one of {ANTHROPIC_API_KEY, OPENAI_API_KEY, GEMINI_API_KEY} matches.

  Heads-up: opencode is *not* pre-installed on the sprite base image —
  the first session on a new sprite will install it (10–30s longer than
  the other runtimes). Subsequent turns on the same sprite are normal
  speed.
  """

  @behaviour AgentOnDemand.Runtimes

  @impl true
  def build_command(agent, _prompt, mode, _runtime_session_id, _opts) do
    base = ["run", "--model", agent.model, "--format", "json"]
    args = if mode == :continue, do: base ++ ["--continue"], else: base
    {"opencode", args, []}
  end

  @impl true
  def default_env(%{model: model}) when is_binary(model) do
    case provider_of(model) do
      "anthropic" -> env_pair("ANTHROPIC_API_KEY", :anthropic_api_key)
      "openai" -> env_pair("OPENAI_API_KEY", :openai_api_key)
      "google" -> env_pair("GEMINI_API_KEY", :gemini_api_key)
      _ -> []
    end
  end

  def default_env(_), do: []

  defp provider_of(model) do
    case String.split(model, "/", parts: 2) do
      [p, _] -> p
      _ -> nil
    end
  end

  defp env_pair(name, config_key) do
    case Application.get_env(:agent_on_demand, config_key) do
      nil -> []
      "" -> []
      value -> [{name, value}]
    end
  end
end
