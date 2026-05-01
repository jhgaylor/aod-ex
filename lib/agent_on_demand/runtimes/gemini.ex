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
  def build_command(agent, _prompt, mode, _runtime_session_id, _opts) do
    base = [
      "--output-format",
      "stream-json",
      # `yolo` auto-approves tool calls — matches claude's
      # `--dangerously-skip-permissions` and codex's
      # `--dangerously-bypass-approvals-and-sandbox`.
      "--approval-mode",
      "yolo"
    ]

    # Non-interactive gemini does NOT load MCP tools by default. The
    # `--allowed-mcp-server-names` flag is the explicit allow-list.
    mcp_args =
      case mcp_server_names(agent) do
        [] -> []
        names -> ["--allowed-mcp-server-names" | names]
      end

    resume = if mode == :continue, do: ["--resume"], else: []

    {"gemini", resume ++ base ++ mcp_args, []}
  end

  defp mcp_server_names(%{mcp_servers: m}) when is_map(m) and m != %{},
    do: m |> Map.keys() |> Enum.map(&to_string/1)

  defp mcp_server_names(_), do: []

  @impl true
  def default_env(_agent) do
    base =
      case Application.get_env(:agent_on_demand, :gemini_api_key) do
        nil -> []
        "" -> []
        key -> [{"GEMINI_API_KEY", key}]
      end

    # gemini-cli aborts during init if it can't rename
    # `~/.gemini/projects.json.tmp` → `projects.json`. The sprite user
    # can write into /home/sprite/.gemini at first glance (ACLs let `ls`
    # and most writes through), but rename across that boundary errors
    # out. /tmp side-steps it cleanly. Mirrors the same fix we needed
    # for opencode's `~/.opencode` access path.
    base ++ [{"HOME", "/tmp"}]
  end

  # Gemini reads user-scope MCP servers from `$HOME/.gemini/settings.json`,
  # under `mcpServers` (camelCase, same shape as Claude). Because we run
  # with HOME=/tmp, that's where the read happens — write there.
  @impl true
  def write_config(_sprite, nil), do: :ok
  def write_config(_sprite, %{mcp_servers: m}) when m == %{} or is_nil(m), do: :ok

  def write_config(sprite, %{mcp_servers: mcp_servers}) do
    fs = Sprites.filesystem(sprite, "/")
    payload = Jason.encode!(%{"mcpServers" => mcp_servers}, pretty: true)

    # /tmp is the live read path under HOME=/tmp. Keep /home/sprite in
    # sync as a courtesy for an operator shelling in without HOME set.
    Sprites.Filesystem.mkdir_p(fs, "/tmp/.gemini")
    Sprites.Filesystem.write(fs, "/tmp/.gemini/settings.json", payload)

    Sprites.Filesystem.mkdir_p(fs, "/home/sprite/.gemini")
    Sprites.Filesystem.write(fs, "/home/sprite/.gemini/settings.json", payload)
    :ok
  end
end
