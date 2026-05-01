defmodule AgentOnDemand.Conversations.Provisioning do
  @moduledoc """
  Provisioning steps that run inside a freshly-created sprite, before the
  runtime CLI is spawned. Each step publishes its own stage events so the
  UI/SSE clients can show progress.

  Order in `ConversationServer.handle_continue(:provision)`:
    1. mount skills (filesystem write — fast)
    2. `apply_network_policy/3` (sprite API call — fast)
    3. `install_packages/4` (apt/npm — slow)
    4. `clone_repositories/4` (git clone — slow)
    5. user's `setup_script` (whatever they supplied)
    6. write runtime-specific config (e.g. claude `~/.claude.json`)

  Each step is a no-op when the corresponding field is empty, so legacy
  environments with bare config (just a name) provision instantly.
  """

  alias AgentOnDemand.Conversations
  alias AgentOnDemand.Environments.Environment

  require Logger

  # ── packages ──────────────────────────────────────────────────────────────

  @doc """
  Install OS / language packages declared on the env. Recognized keys:

      packages: %{
        "apt" => ["jq", "ripgrep"],
        "npm" => ["typescript", "@anthropic-ai/sdk"]
      }

  Anything else is silently ignored. Returns `:ok` on success, `{:error,
  {step, exit_code, output}}` on first failure (sprite kept alive so the
  caller can decide whether to destroy).
  """
  def install_packages(_sprite, nil, _sprite_env, _conv_id), do: :ok

  def install_packages(sprite, %Environment{} = env, sprite_env, conv_id) do
    case build_package_commands(env.packages || %{}) do
      [] ->
        :ok

      cmds ->
        publish_stage(conv_id, "packages", "started", %{commands: length(cmds)})

        result =
          Enum.reduce_while(cmds, :ok, fn cmd, _ ->
            {output, code} =
              Sprites.cmd(sprite, "bash", ["-lc", cmd],
                env: sprite_env,
                stderr_to_stdout: true,
                timeout: 300_000
              )

            log_output(conv_id, output)

            if code == 0,
              do: {:cont, :ok},
              else: {:halt, {:error, {:packages, code, output}}}
          end)

        case result do
          :ok ->
            publish_stage(conv_id, "packages", "done")
            :ok

          {:error, {:packages, code, _}} = err ->
            publish_stage(conv_id, "packages", "failed", %{exit_code: code})
            err
        end
    end
  end

  @doc false
  def build_package_commands(%{} = pkgs) do
    apt_cmds = build_apt_commands(Map.get(pkgs, "apt", []))
    npm_cmds = build_npm_commands(Map.get(pkgs, "npm", []))
    apt_cmds ++ npm_cmds
  end

  def build_package_commands(_), do: []

  @doc false
  def build_apt_commands([]), do: []

  def build_apt_commands(list) when is_list(list) do
    quoted = list |> Enum.filter(&is_binary/1) |> Enum.map_join(" ", &shell_quote/1)

    if quoted == "",
      do: [],
      else: [
        "sudo apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq #{quoted}"
      ]
  end

  @doc false
  def build_npm_commands([]), do: []

  def build_npm_commands(list) when is_list(list) do
    quoted = list |> Enum.filter(&is_binary/1) |> Enum.map_join(" ", &shell_quote/1)
    if quoted == "", do: [], else: ["npm install -g --no-progress --silent #{quoted}"]
  end

  # ── network policy ────────────────────────────────────────────────────────

  @doc """
  Apply the env's networking config to the sprite. `unrestricted` is a
  no-op (sprites are open by default). `limited` builds an allowlist from
  `networking_config.allowed_hosts: [...]`.
  """
  def apply_network_policy(_sprite, nil, _conv_id), do: :ok

  def apply_network_policy(_sprite, %Environment{networking_type: "unrestricted"}, _conv_id),
    do: :ok

  def apply_network_policy(sprite, %Environment{networking_type: "limited"} = env, conv_id) do
    hosts = get_in(env.networking_config, ["allowed_hosts"]) || []

    rules =
      Enum.map(hosts, fn h ->
        %Sprites.Policy.Rule{domain: h, action: "allow"}
      end)

    publish_stage(conv_id, "network", "started", %{type: "limited", hosts: length(hosts)})

    case Sprites.update_network_policy(sprite, %Sprites.Policy{rules: rules}) do
      :ok ->
        publish_stage(conv_id, "network", "done")
        :ok

      {:error, reason} ->
        publish_stage(conv_id, "network", "failed", %{reason: inspect(reason)})
        {:error, {:network_policy, reason}}
    end
  end

  def apply_network_policy(_sprite, _env, _conv_id), do: :ok

  # ── git clone ─────────────────────────────────────────────────────────────

  @doc """
  Clone every repository declared on the env into the sprite at its
  `mount_path`. HTTPS only, x-access-token auth via the env secret named
  by `secret_key`. Returns `:ok` or `{:error, ...}` on first failure.
  """
  def clone_repositories(_sprite, nil, _secrets, _conv_id), do: :ok

  def clone_repositories(_sprite, %Environment{repositories: repos}, _secrets, _conv_id)
      when repos in [nil, []],
      do: :ok

  def clone_repositories(sprite, %Environment{repositories: repos}, secrets, conv_id) do
    publish_stage(conv_id, "clone", "started", %{count: length(repos)})

    Enum.reduce_while(repos, :ok, fn repo, _ ->
      case clone_one(sprite, repo, secrets, conv_id) do
        :ok -> {:cont, :ok}
        err -> {:halt, err}
      end
    end)
    |> case do
      :ok ->
        publish_stage(conv_id, "clone", "done")
        :ok

      {:error, reason} = err ->
        publish_stage(conv_id, "clone", "failed", %{reason: inspect(reason)})
        err
    end
  end

  defp clone_one(sprite, %{"url" => url, "mount_path" => mount} = repo, secrets, conv_id) do
    auth_url = inject_token(url, repo["secret_key"], secrets)
    ref = repo["ref"]

    branch_arg = if is_binary(ref) and ref != "", do: "-b #{shell_quote(ref)} ", else: ""

    cmd =
      "mkdir -p #{shell_quote(Path.dirname(mount))} && " <>
        "git clone --depth 50 #{branch_arg}#{shell_quote(auth_url)} #{shell_quote(mount)}"

    {output, code} =
      Sprites.cmd(sprite, "bash", ["-lc", cmd],
        stderr_to_stdout: true,
        timeout: 600_000
      )

    log_output(conv_id, scrub_token(output))

    if code == 0,
      do: :ok,
      else: {:error, {:clone, url, code}}
  end

  defp clone_one(_, repo, _, _), do: {:error, {:clone_invalid_spec, repo}}

  @doc false
  def inject_token(url, nil, _), do: url
  def inject_token(url, "", _), do: url

  def inject_token(url, key, secrets) when is_map(secrets) do
    case Map.get(secrets, key) do
      nil -> url
      "" -> url
      token -> rewrite_https_with_token(url, token)
    end
  end

  def inject_token(url, _, _), do: url

  @doc false
  def rewrite_https_with_token("https://" <> rest, token) do
    "https://x-access-token:#{token}@" <> rest
  end

  def rewrite_https_with_token(url, _), do: url

  # Avoid leaking the token into log_events when git's clone output echoes
  # the URL back (it sometimes does on auth errors).
  @doc false
  def scrub_token(s) when is_binary(s),
    do: Regex.replace(~r{https://x-access-token:[^@]+@}, s, "https://x-access-token:***@")

  def scrub_token(s), do: s

  # ── helpers ───────────────────────────────────────────────────────────────

  @doc false
  def shell_quote(s), do: "'" <> String.replace(s, "'", "'\\''") <> "'"

  defp publish_stage(conv_id, stage, state, meta \\ %{}) do
    Conversations.log!(%{
      conversation_id: conv_id,
      kind: "stage",
      stage: stage,
      state: state,
      data: Jason.encode!(meta)
    })
    |> tap(fn ev ->
      Phoenix.PubSub.broadcast(AgentOnDemand.PubSub, "conv:#{conv_id}", {:log_event, ev})
    end)
  end

  defp log_output(conv_id, output) when is_binary(output) and output != "" do
    Conversations.log!(%{
      conversation_id: conv_id,
      kind: "output",
      stream: "stdout",
      data: output
    })
    |> tap(fn ev ->
      Phoenix.PubSub.broadcast(AgentOnDemand.PubSub, "conv:#{conv_id}", {:log_event, ev})
    end)
  end

  defp log_output(_, _), do: :ok
end
