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

  # codex 0.118+ does NOT read OPENAI_API_KEY at exec time — it only reads
  # `~/.codex/auth.json`, which `codex login --with-api-key` writes by
  # consuming the key on stdin. Run the login once at provision time.
  @impl true
  def prepare_sprite(sprite, _agent, sprite_env) do
    case List.keyfind(sprite_env, "OPENAI_API_KEY", 0) do
      {"OPENAI_API_KEY", key} when is_binary(key) and key != "" ->
        case Sprites.spawn(sprite, "codex", ["login", "--with-api-key"],
               owner: self(),
               stdin: true,
               env: sprite_env
             ) do
          {:ok, command} ->
            :ok = Sprites.write(command, key <> "\n")
            :ok = Sprites.close_stdin(command)

            receive do
              {:exit, %{ref: ref}, 0} when ref == command.ref ->
                :ok

              {:exit, %{ref: ref}, code} when ref == command.ref ->
                {:error, {:codex_login_exit, code}}
            after
              30_000 -> {:error, :codex_login_timeout}
            end

          err ->
            {:error, {:codex_login_spawn, err}}
        end

      _ ->
        # No key in env — surface that explicitly; without it the
        # subsequent `codex exec` will 401 with a confusing message.
        {:error, :missing_openai_api_key}
    end
  end
end
