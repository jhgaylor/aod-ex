defmodule AodCli.Up do
  @moduledoc """
  Deploy AoD into a Sprite, or upgrade an existing deployment in place.

  Invoked from two places:
    * `mix aod.up` (Mix task wrapper) — runs from a project checkout.
    * `./aod up` (the released binary's CLI mode) — runs anywhere,
      no Erlang install or repo needed.

  Both paths land here.

  Reads `SPRITES_TOKEN` from env (or a `.env` in the current dir).

  ## Binary source

  Pushes the Linux Burrito binary to the sprite. Resolution order:

    1. Local build at `burrito_out/aod_linux` — used if it exists
       (ideal for dev iteration: `MIX_ENV=prod mix release`).
    2. Otherwise, downloads the binary from the project's GitHub
       release matching the current build version. Cached under
       `~/.cache/aod/releases/<tag>/` (or `$XDG_CACHE_HOME/aod/...`).

  Override the release with `--release vX.Y.Z` (or just `0.1.0`).

  ## Deploy (fresh)

  Without `--name`, or with a `--name` that doesn't exist yet at
  sprites.dev, runs the full deploy: provision a sprite, generate
  fresh secrets, push the binary, register the service, poll
  `/health`, print the URL + admin token.

  ## Upgrade (in place)

  When `--name` matches an existing sprite, runs the upgrade flow
  instead: recover the secrets we wrote into `/opt/aod/start.sh` on
  the original deploy, push the new binary on top of the old one,
  rewrite `start.sh` (env shape may have evolved between releases),
  recreate the `sprite-env` service so it picks up the new binary,
  poll `/health`. The SQLite DB at `/opt/aod/data/aod.db` and the
  encryption key are preserved.
  """

  # Captured at compile time so the released binary embeds whatever
  # version it was built at. Mix isn't available at runtime in a
  # release.
  @app_version Mix.Project.config()[:version]

  @local_binary_path "burrito_out/aod_linux"
  @release_asset_name "aod-linux-x86_64"
  @github_repo "jhgaylor/aod-ex"
  @remote_binary "/opt/aod/aod"
  @remote_start_sh "/opt/aod/start.sh"
  @remote_db "/opt/aod/data/aod.db"
  @port 4000

  @doc """
  Entry point. Parses args (passed through from either the Mix task
  wrapper or the AodCli main dispatcher) and runs the deploy/upgrade.
  """
  def dispatch(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [name: :string, release: :string]
      )

    Application.ensure_all_started(:req)
    Application.ensure_all_started(:gun)
    Application.ensure_all_started(:sprites)

    token =
      System.get_env("SPRITES_TOKEN") || load_dot_env("SPRITES_TOKEN") ||
        AodCli.die("SPRITES_TOKEN not set")

    client = Sprites.new(token)

    case opts[:name] do
      nil ->
        binary_path = resolve_binary_path(opts[:release])
        deploy(client, "aod-host-#{:os.system_time(:second)}", binary_path)

      name ->
        binary_path = resolve_binary_path(opts[:release])

        case Sprites.get_sprite(client, name) do
          {:ok, _info} ->
            upgrade(client, name, binary_path)

          {:error, {:not_found, _}} ->
            deploy(client, name, binary_path)

          {:error, reason} ->
            AodCli.die("could not check sprite '#{name}': #{inspect(reason)}")
        end
    end
  end

  # ── binary resolution ────────────────────────────────────────────

  defp resolve_binary_path(nil) do
    cond do
      File.exists?(@local_binary_path) ->
        info("using local build: #{@local_binary_path}")
        Path.expand(@local_binary_path)

      true ->
        tag = "v" <> @app_version

        info(
          "no local build found at #{@local_binary_path}; falling back to GitHub release #{tag}"
        )

        download_release_binary(tag)
    end
  end

  defp resolve_binary_path(release_arg) when is_binary(release_arg) do
    tag = if String.starts_with?(release_arg, "v"), do: release_arg, else: "v" <> release_arg
    info("using GitHub release #{tag} (--release override)")
    download_release_binary(tag)
  end

  @doc false
  def download_release_binary(tag) do
    cache_dir = Path.join(cache_root(), tag)
    cache_path = Path.join(cache_dir, @release_asset_name)

    if File.exists?(cache_path) do
      info("cached: #{cache_path}")
      cache_path
    else
      File.mkdir_p!(cache_dir)

      token = resolve_github_token()
      asset_id = lookup_asset_id(tag, token)

      url = "https://api.github.com/repos/#{@github_repo}/releases/assets/#{asset_id}"

      info("downloading #{@release_asset_name} from #{tag}...")

      headers = [
        {"accept", "application/octet-stream"},
        {"x-github-api-version", "2022-11-28"}
        | auth_header(token)
      ]

      result =
        Req.get(
          url,
          headers: headers,
          redirect: true,
          # Let the redirect to objects.githubusercontent.com proceed
          # without forwarding our Authorization header (Req strips it
          # on cross-host redirects by default — explicit here as a
          # safety pin).
          redirect_log_level: false,
          receive_timeout: 120_000,
          into: File.stream!(cache_path)
        )

      case result do
        {:ok, %{status: 200}} ->
          File.chmod!(cache_path, 0o755)
          info("saved to #{cache_path} (#{File.stat!(cache_path).size |> human_size})")
          cache_path

        {:ok, %{status: status}} ->
          File.rm(cache_path)

          AodCli.die(
            "release download failed: GET #{url} returned HTTP #{status} " <>
              github_auth_hint(token, status)
          )

        {:error, reason} ->
          File.rm(cache_path)
          AodCli.die("release download failed: #{inspect(reason)}")
      end
    end
  end

  defp lookup_asset_id(tag, token) do
    url = "https://api.github.com/repos/#{@github_repo}/releases/tags/#{tag}"

    headers = [
      {"accept", "application/vnd.github+json"},
      {"x-github-api-version", "2022-11-28"}
      | auth_header(token)
    ]

    case Req.get(url, headers: headers, redirect: true, receive_timeout: 30_000) do
      {:ok, %{status: 200, body: %{"assets" => assets}}} ->
        case Enum.find(assets, &(&1["name"] == @release_asset_name)) do
          %{"id" => id} ->
            id

          nil ->
            available = assets |> Enum.map(& &1["name"]) |> Enum.join(", ")

            AodCli.die(
              "release #{tag} has no asset named `#{@release_asset_name}` " <>
                "(found: #{available})"
            )
        end

      {:ok, %{status: status}} ->
        AodCli.die(
          "could not look up release #{tag}: GET #{url} returned HTTP #{status} " <>
            github_auth_hint(token, status)
        )

      {:error, reason} ->
        AodCli.die("could not look up release #{tag}: #{inspect(reason)}")
    end
  end

  defp cache_root do
    base = System.get_env("XDG_CACHE_HOME") || Path.join(System.user_home!(), ".cache")
    Path.join([base, "aod", "releases"])
  end

  defp resolve_github_token do
    case System.get_env("GITHUB_TOKEN") do
      token when is_binary(token) and token != "" ->
        token

      _ ->
        case System.find_executable("gh") do
          nil ->
            nil

          gh ->
            case System.cmd(gh, ["auth", "token"], stderr_to_stdout: true) do
              {out, 0} -> String.trim(out)
              _ -> nil
            end
        end
    end
  end

  defp auth_header(nil), do: []
  defp auth_header(""), do: []
  defp auth_header(token), do: [{"authorization", "Bearer " <> token}]

  defp github_auth_hint(nil, status) when status in [401, 403, 404] do
    "(private repo? export GITHUB_TOKEN=... or run `gh auth login` so we can pick the token up)"
  end

  defp github_auth_hint(_, _), do: "(does the tag exist with an `#{@release_asset_name}` asset?)"

  # ── deploy ───────────────────────────────────────────────────────

  defp deploy(client, name, binary_path) do
    info("provisioning sprite '#{name}'...")
    {:ok, sprite} = Sprites.create(client, name)

    info("flipping URL auth to public...")
    :ok = Sprites.update_url_settings(sprite, %{auth: "public"})

    info("looking up public hostname...")
    {:ok, sprite_info} = Sprites.get_sprite(client, name)
    public_url = extract_public_url(sprite_info, @port) || raise("no public URL on sprite")
    info("public url: #{public_url}")

    info("pushing binary (#{File.stat!(binary_path).size |> human_size}) to sprite...")
    fs = Sprites.filesystem(sprite, "/")
    binary = File.read!(binary_path)
    :ok = Sprites.Filesystem.write(fs, @remote_binary, binary, mode: 0o755)
    info("binary pushed.")

    info("creating data dir...")
    {_, 0} = Sprites.cmd(sprite, "mkdir", ["-p", "/opt/aod/data"])

    secrets = %{
      admin_token: random_hex(24),
      secrets_key: random_url64(32),
      secret_key_base: random_hex(64)
    }

    env = build_env(secrets, public_url)

    info("writing #{@remote_start_sh} wrapper...")
    fs = Sprites.filesystem(sprite, "/")
    :ok = Sprites.Filesystem.write(fs, @remote_start_sh, start_script(env), mode: 0o755)

    info("registering service via sprite-env (survives hibernation)...")
    {_, _} = Sprites.cmd(sprite, "/.sprite/bin/sprite-env", ["services", "delete", "aod"])

    {out, code} =
      Sprites.cmd(
        sprite,
        "/.sprite/bin/sprite-env",
        [
          "services",
          "create",
          "aod",
          "--cmd",
          @remote_start_sh,
          "--http-port",
          Integer.to_string(@port),
          "--no-stream"
        ],
        timeout: 30_000,
        stderr_to_stdout: true
      )

    if code != 0, do: raise("sprite-env services create failed (code #{code}):\n#{out}")
    info("service registered: #{String.trim(out)}")

    info("polling /health (will auto-start service on first hit)...")
    wait_for_health(public_url)

    IO.puts("""

    ============================================================
    AoD is live!

      URL:           #{public_url}
      ADMIN_TOKEN:   #{secrets.admin_token}
      Sprite name:   #{name}

    Login at the URL with the ADMIN_TOKEN above.

    Tear down later with:
      aod down #{name}
    ============================================================
    """)
  end

  # ── upgrade ──────────────────────────────────────────────────────

  defp upgrade(client, name, binary_path) do
    info("upgrading sprite '#{name}' in place...")
    sprite = Sprites.sprite(client, name)

    info("recovering env from #{@remote_start_sh}...")
    env = read_existing_env(sprite)

    public_url =
      env_get(env, "AOD_PUBLIC_URL") ||
        AodCli.die("could not recover AOD_PUBLIC_URL from existing #{@remote_start_sh}")

    admin_token = env_get(env, "ADMIN_TOKEN") || "<unchanged>"

    info("pushing binary (#{File.stat!(binary_path).size |> human_size}) to sprite...")
    fs = Sprites.filesystem(sprite, "/")
    binary = File.read!(binary_path)
    :ok = Sprites.Filesystem.write(fs, @remote_binary, binary, mode: 0o755)
    info("binary pushed.")

    info("rewriting #{@remote_start_sh} (env shape may have changed)...")
    :ok = Sprites.Filesystem.write(fs, @remote_start_sh, start_script(env), mode: 0o755)

    info("recreating sprite-env service so it picks up the new binary...")
    {_, _} = Sprites.cmd(sprite, "/.sprite/bin/sprite-env", ["services", "delete", "aod"])

    {out, code} =
      Sprites.cmd(
        sprite,
        "/.sprite/bin/sprite-env",
        [
          "services",
          "create",
          "aod",
          "--cmd",
          @remote_start_sh,
          "--http-port",
          Integer.to_string(@port),
          "--no-stream"
        ],
        timeout: 30_000,
        stderr_to_stdout: true
      )

    if code != 0, do: raise("sprite-env services create failed (code #{code}):\n#{out}")
    info("service registered: #{String.trim(out)}")

    info("polling /health...")
    wait_for_health(public_url)

    IO.puts("""

    ============================================================
    AoD upgraded!

      URL:           #{public_url}
      ADMIN_TOKEN:   #{admin_token}
      Sprite name:   #{name}

    ============================================================
    """)
  end

  defp read_existing_env(sprite) do
    {output, code} =
      Sprites.cmd(sprite, "cat", [@remote_start_sh], stderr_to_stdout: true)

    if code != 0 do
      AodCli.die("could not read #{@remote_start_sh} (exit #{code}):\n#{output}")
    end

    parse_start_sh(output)
  end

  # ── start.sh writer/parser ───────────────────────────────────────
  # We wrote start.sh ourselves with `export KEY='value'` lines, where
  # any embedded `'` was encoded as `'"'"'`. So the parser is the
  # inverse — pull out KEY/value pairs and unwrap.

  @doc false
  def parse_start_sh(content) do
    content
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/^export ([A-Z_][A-Z0-9_]*)=(.*)$/, String.trim(line)) do
        [_, key, value] -> [{key, unquote_shell(value)}]
        _ -> []
      end
    end)
  end

  @doc false
  def shell_quote(value) do
    "'" <> String.replace(value, "'", ~S('"'"')) <> "'"
  end

  defp unquote_shell("'" <> rest) do
    rest
    |> String.replace_suffix("'", "")
    |> String.replace(~S('"'"'), "'")
  end

  defp unquote_shell(s), do: s

  defp env_get(env, key) do
    case List.keyfind(env, key, 0) do
      {_, v} -> v
      nil -> nil
    end
  end

  defp start_script(env) do
    exports =
      env
      |> Enum.map(fn {k, v} -> "export #{k}=#{shell_quote(v)}" end)
      |> Enum.join("\n")

    """
    #!/bin/sh
    set -eu
    #{exports}
    exec #{@remote_binary} start
    """
  end

  defp build_env(secrets, public_url) do
    %URI{host: host} = URI.parse(public_url)

    [
      {"PHX_SERVER", "1"},
      {"PHX_HOST", host},
      {"PORT", Integer.to_string(@port)},
      {"RELEASE_NAME", "aod"},
      {"SECRET_KEY_BASE", secrets.secret_key_base},
      {"ADMIN_TOKEN", secrets.admin_token},
      {"SECRETS_KEY", secrets.secrets_key},
      {"DATABASE_PATH", @remote_db},
      {"AOD_PUBLIC_URL", public_url}
    ]
  end

  defp extract_public_url(info, port) do
    candidates =
      for k <- ~w(public_url url hostname public_hostname),
          v = Map.get(info, k) || get_in(info, [k]),
          is_binary(v),
          do: v

    case candidates do
      [host_or_url | _] ->
        cond do
          String.starts_with?(host_or_url, "http") ->
            host_or_url

          true ->
            "https://#{host_or_url}:#{port}"
        end

      [] ->
        for {_k, v} <- info, is_map(v), reduce: nil do
          acc -> acc || extract_public_url(v, port)
        end
    end
  end

  defp wait_for_health(url, attempts \\ 60) do
    Enum.reduce_while(1..attempts, nil, fn n, _ ->
      case Req.get(url <> "/health", retry: false, receive_timeout: 5_000) do
        {:ok, %{status: 200, body: %{"status" => "ok"}}} ->
          info("/health 200 OK after #{n} tries.")
          {:halt, :ok}

        {:ok, %{status: code}} ->
          info("attempt #{n}: /health -> #{code}")
          Process.sleep(2_000)
          {:cont, nil}

        {:error, reason} ->
          info("attempt #{n}: #{inspect(reason)}")
          Process.sleep(2_000)
          {:cont, nil}
      end
    end)
    |> case do
      :ok -> :ok
      _ -> raise "/health never responded 200 OK"
    end
  end

  defp random_hex(bytes), do: :crypto.strong_rand_bytes(bytes) |> Base.encode16(case: :lower)

  defp random_url64(bytes),
    do: :crypto.strong_rand_bytes(bytes) |> Base.url_encode64(padding: false)

  defp human_size(bytes) when bytes > 1_000_000,
    do: "#{Float.round(bytes / 1_000_000, 1)} MB"

  defp human_size(bytes), do: "#{bytes} B"

  defp info(msg), do: IO.puts("→ #{msg}")

  defp load_dot_env(key) do
    path = Path.expand(".env")

    if File.exists?(path) do
      path
      |> File.read!()
      |> String.split("\n")
      |> Enum.find_value(fn line ->
        case String.split(String.trim(line), "=", parts: 2) do
          [^key, value] -> value |> String.trim() |> String.trim("\"")
          _ -> nil
        end
      end)
    end
  end
end
