defmodule Mix.Tasks.Aod.Up do
  @moduledoc """
  Deploy AoD into a Sprite, or upgrade an existing deployment in place.

  Reads `SPRITES_TOKEN` from env (or `.env`). Builds nothing — assumes
  the Linux Burrito binary is at `burrito_out/agent_on_demand_linux`.

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

      SPRITES_TOKEN=... mix aod.up --name my-aod   # → upgrade if exists

  ## Tear down

  Use `mix aod.down <name>`.
  """
  use Mix.Task

  @shortdoc "Deploy AoD to a Sprite (or upgrade in place)"

  @binary_path "burrito_out/agent_on_demand_linux"
  @remote_binary "/opt/aod/aod"
  @remote_start_sh "/opt/aod/start.sh"
  @remote_db "/opt/aod/data/aod.db"
  @port 4000

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [name: :string, destroy: :string]
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
        case Sprites.get_sprite(client, name) do
          {:ok, _info} -> upgrade(client, name)
          {:error, {:not_found, _}} -> deploy(client, name)
          {:error, reason} -> Mix.raise("could not check sprite '#{name}': #{inspect(reason)}")
        end

      true ->
        deploy(client, "aod-host-#{:os.system_time(:second)}")
    end
  end

  defp deploy(client, name) do
    info("provisioning sprite '#{name}'...")
    {:ok, sprite} = Sprites.create(client, name)

    info("flipping URL auth to public...")
    :ok = Sprites.update_url_settings(sprite, %{auth: "public"})

    info("looking up public hostname...")
    {:ok, sprite_info} = Sprites.get_sprite(client, name)
    public_url = extract_public_url(sprite_info, @port) || raise("no public URL on sprite")
    info("public url: #{public_url}")

    info("pushing binary (#{File.stat!(@binary_path).size |> human_size}) to sprite...")
    fs = Sprites.filesystem(sprite, "/")
    binary = File.read!(@binary_path)
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
  defp upgrade(client, name) do
    info("upgrading sprite '#{name}' in place...")
    sprite = Sprites.sprite(client, name)

    info("recovering env from #{@remote_start_sh}...")
    env = read_existing_env(sprite)

    public_url =
      env_get(env, "AOD_PUBLIC_URL") ||
        Mix.raise("could not recover AOD_PUBLIC_URL from existing #{@remote_start_sh}")

    admin_token = env_get(env, "ADMIN_TOKEN") || "<unchanged>"

    info("pushing binary (#{File.stat!(@binary_path).size |> human_size}) to sprite...")
    fs = Sprites.filesystem(sprite, "/")
    binary = File.read!(@binary_path)
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
