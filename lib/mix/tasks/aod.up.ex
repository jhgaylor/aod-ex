defmodule Mix.Tasks.Aod.Up do
  @moduledoc """
  Deploy AoD into a Sprite, or upgrade an existing deployment in place.

  Reads `SPRITES_TOKEN` from env (or `.env`).

  ## Binary source

  Pushes the Linux Burrito binary to the sprite. Resolution order:

    1. Local build at `burrito_out/aod_linux` — used if it exists
       (ideal for dev iteration: `MIX_ENV=prod mix release`).
    2. Otherwise, downloads the binary from the project's GitHub
       release matching the current `mix.exs` version (e.g. v0.1.0)
       into `_build/aod-releases/<version>/`. Cached so repeat
       deploys don't re-download.

  Override the release with `--release vX.Y.Z` (or just `0.1.0`).

  ## Deploy (fresh)

  Without `--name`, or with a `--name` that doesn't exist yet at
  sprites.dev, runs the full deploy: provision a sprite, generate
  fresh secrets, push the binary, register the service, poll
  `/health`, print the URL + admin token.

      SPRITES_TOKEN=... mix aod.up
      SPRITES_TOKEN=... mix aod.up --name my-aod

  ## Upgrade (in place)

  When `--name` matches an existing sprite, runs the upgrade flow
  instead: recover the secrets we wrote into `/opt/aod/start.sh` on
  the original deploy, push the new binary on top of the old one,
  rewrite `start.sh` (env shape may have evolved between releases),
  recreate the `sprite-env` service so it picks up the new binary,
  poll `/health`. The SQLite DB at `/opt/aod/data/aod.db` and the
  encryption key are preserved, so existing agents/environments/
  vaults/conversations survive the upgrade.

      SPRITES_TOKEN=... mix aod.up --name my-aod                 # local build
      SPRITES_TOKEN=... mix aod.up --name my-aod --release v0.1.0 # specific release

  ## Tear down

  Use `mix aod.down <name>`.
  """
  use Mix.Task

  @shortdoc "Deploy AoD to a Sprite (or upgrade in place)"

  @local_binary_path "burrito_out/aod_linux"
  @release_asset_name "aod-linux-x86_64"
  @github_repo "jhgaylor/aod-ex"
  @remote_binary "/opt/aod/aod"
  @remote_start_sh "/opt/aod/start.sh"
  @remote_db "/opt/aod/data/aod.db"
  @port 4000

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [name: :string, destroy: :string, release: :string]
      )

    Application.ensure_all_started(:req)
    Application.ensure_all_started(:gun)
    Application.ensure_all_started(:sprites)

    token =
      System.get_env("SPRITES_TOKEN") || load_dot_env("SPRITES_TOKEN") ||
        raise("SPRITES_TOKEN not set")

    client = Sprites.new(token)

    cond do
      destroy = opts[:destroy] ->
        IO.puts(
          :stderr,
          "warning: `mix aod.up --destroy <name>` is deprecated; use `mix aod.down <name>` instead."
        )

        Mix.Tasks.Aod.Down.destroy(client, destroy)

      name = opts[:name] ->
        binary_path = resolve_binary_path(opts[:release])

        case Sprites.get_sprite(client, name) do
          {:ok, _info} -> upgrade(client, name, binary_path)
          {:error, {:not_found, _}} -> deploy(client, name, binary_path)
          {:error, reason} -> Mix.raise("could not check sprite '#{name}': #{inspect(reason)}")
        end

      true ->
        binary_path = resolve_binary_path(opts[:release])
        deploy(client, "aod-host-#{:os.system_time(:second)}", binary_path)
    end
  end

  # Returns an absolute path to the linux binary we'll push into the
  # sprite. Local build (`burrito_out/aod_linux`) wins if present and
  # no explicit `--release` was passed; otherwise we download from the
  # GitHub release.
  defp resolve_binary_path(nil) do
    cond do
      File.exists?(@local_binary_path) ->
        info("using local build: #{@local_binary_path}")
        Path.expand(@local_binary_path)

      true ->
        version = Mix.Project.config()[:version]
        tag = "v" <> version

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

  defp download_release_binary(tag) do
    cache_dir = Path.join([Mix.Project.build_path(), "..", "..", "_build", "aod-releases", tag])
    cache_dir = Path.expand(cache_dir)
    cache_path = Path.join(cache_dir, @release_asset_name)

    if File.exists?(cache_path) do
      info("cached: #{cache_path}")
      cache_path
    else
      File.mkdir_p!(cache_dir)

      url =
        "https://github.com/#{@github_repo}/releases/download/#{tag}/#{@release_asset_name}"

      info("downloading #{url}...")

      case Req.get(url, redirect: true, receive_timeout: 120_000, into: File.stream!(cache_path)) do
        {:ok, %{status: 200}} ->
          File.chmod!(cache_path, 0o755)
          info("saved to #{cache_path} (#{File.stat!(cache_path).size |> human_size})")
          cache_path

        {:ok, %{status: status}} ->
          File.rm(cache_path)

          Mix.raise(
            "release download failed: GET #{url} returned HTTP #{status} " <>
              "(does the tag exist with an `#{@release_asset_name}` asset?)"
          )

        {:error, reason} ->
          File.rm(cache_path)
          Mix.raise("release download failed: #{inspect(reason)}")
      end
    end
  end

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
    # Delete any prior registration so re-runs are idempotent.
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
          "/opt/aod/start.sh",
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
      mix aod.down #{name}
    ============================================================
    """)
  end

  # In-place binary swap. Recovers the existing env (admin token,
  # secrets key, etc.) from start.sh on the sprite so the freshly-
  # pushed binary can decrypt the existing SQLite DB.
  defp upgrade(client, name, binary_path) do
    info("upgrading sprite '#{name}' in place...")
    sprite = Sprites.sprite(client, name)

    info("recovering env from #{@remote_start_sh}...")
    env = read_existing_env(sprite)

    public_url =
      env_get(env, "AOD_PUBLIC_URL") ||
        Mix.raise("could not recover AOD_PUBLIC_URL from existing #{@remote_start_sh}")

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
      Mix.raise("could not read #{@remote_start_sh} (exit #{code}):\n#{output}")
    end

    parse_start_sh(output)
  end

  # We wrote start.sh ourselves with `export KEY='value'` lines, where
  # any embedded `'` was encoded as `'"'"'` (see shell_quote/1). So
  # the parser is the inverse — pull out KEY/value pairs and unwrap.
  defp parse_start_sh(content) do
    content
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/^export ([A-Z_][A-Z0-9_]*)=(.*)$/, String.trim(line)) do
        [_, key, value] -> [{key, unquote_shell(value)}]
        _ -> []
      end
    end)
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

  defp shell_quote(value) do
    "'" <> String.replace(value, "'", ~S('"'"')) <> "'"
  end

  defp build_env(secrets, public_url) do
    %URI{host: host} = URI.parse(public_url)

    [
      {"PHX_SERVER", "1"},
      {"PHX_HOST", host},
      {"PORT", Integer.to_string(@port)},
      {"RELEASE_NAME", "agent_on_demand"},
      {"SECRET_KEY_BASE", secrets.secret_key_base},
      {"ADMIN_TOKEN", secrets.admin_token},
      {"SECRETS_KEY", secrets.secrets_key},
      {"DATABASE_PATH", @remote_db},
      {"AOD_PUBLIC_URL", public_url}
    ]
  end

  defp extract_public_url(info, port) do
    # We don't know the field name yet — try the obvious candidates,
    # in order, and fall back to the inspect dump above.
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
        # last-ditch: look one level deep
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
