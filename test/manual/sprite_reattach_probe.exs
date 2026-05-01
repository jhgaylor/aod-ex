# Bare-minimum probe of sprites-ex `detachable: true` + `attach_session`.
#
# Hypothesis: sprites.dev preserves a detached process across websocket
# disconnect, and `attach_session` lets us pick its output back up.
#
# Run with: `mix run --no-start test/manual/sprite_reattach_probe.exs`
# Skip-app start because we don't want the Phoenix endpoint or rehydrator.

# Start only the deps we need.
{:ok, _} = Application.ensure_all_started(:logger)
{:ok, _} = Application.ensure_all_started(:req)
{:ok, _} = Application.ensure_all_started(:gun)
{:ok, _} = Application.ensure_all_started(:sprites)

require Logger

token = System.get_env("SPRITES_TOKEN") || raise "set SPRITES_TOKEN"
client = Sprites.Client.new(token)

name = "probe-reattach-#{:rand.uniform(1_000_000)}"
IO.puts("# creating sprite #{name}")
{:ok, sprite} = Sprites.create(client, name)
IO.puts("# sprite created: id=#{sprite.id}")

# Make absolutely sure we always destroy the sprite, even on crash.
parent = self()

destroy = fn ->
  IO.puts("# destroying sprite #{name}")
  case Sprites.destroy(sprite) do
    :ok -> IO.puts("# destroyed")
    other -> IO.inspect(other, label: "destroy")
  end
end

try do
  # === Phase 1: spawn a long-running detachable command ===
  # Print BEFORE immediately, sleep 20s, print AFTER, exit 0.
  # If sprites preserves the process across disconnect, AFTER should
  # arrive on a reattached websocket.
  IO.puts("\n=== phase 1: spawn detachable bash ===")

  {:ok, cmd1} =
    Sprites.spawn(sprite, "bash",
      ["-c", "echo BEFORE; sleep 20; echo AFTER; echo EXIT_OK"],
      owner: self(),
      detachable: true
    )

  IO.inspect(cmd1, label: "spawn ok")

  before_received? =
    receive do
      {:stdout, %{ref: ref}, data} when ref == cmd1.ref ->
        IO.puts("# stdout: #{inspect(data)}")
        String.contains?(IO.iodata_to_binary(data), "BEFORE")

      msg ->
        IO.inspect(msg, label: "unexpected (phase 1)")
        false
    after
      10_000 ->
        IO.puts("# TIMEOUT waiting for BEFORE")
        false
    end

  unless before_received?, do: raise("phase 1 failed: never saw BEFORE")

  # === Phase 2: list sessions so we know what id we're attaching to ===
  IO.puts("\n=== phase 2: list sessions ===")
  {:ok, sessions_pre} = Sprites.list_sessions(sprite)
  IO.inspect(sessions_pre, label: "sessions before disconnect")

  session_id =
    case sessions_pre do
      [s | _] -> s.id
      [] -> raise "no sessions listed despite a detachable spawn"
    end

  IO.puts("# session_id=#{session_id}")

  # === Phase 3: hard-kill the Command GenServer (simulates BEAM crash) ===
  IO.puts("\n=== phase 3: hard-kill the Command GenServer ===")
  Process.exit(cmd1.pid, :kill)
  Process.sleep(500)
  IO.puts("# Command GenServer alive? #{Process.alive?(cmd1.pid)}")

  # Wait long enough for sprites.dev to notice the WS drop AND for the
  # sprite-side `sleep 20` to keep ticking. Sleep started at ~0s, we
  # just consumed ~1-2s, so AFTER fires at ~+20s wallclock.
  gap_ms = String.to_integer(System.get_env("GAP_MS") || "5000")
  IO.puts("# waiting #{gap_ms}ms with no attached websocket...")
  Process.sleep(gap_ms)

  # === Phase 4: list sessions again — is ours still there? ===
  IO.puts("\n=== phase 4: list sessions while detached ===")
  {:ok, sessions_mid} = Sprites.list_sessions(sprite)
  IO.inspect(sessions_mid, label: "sessions during detach")

  # === Phase 5: reattach ===
  IO.puts("\n=== phase 5: attach_session ===")
  {:ok, cmd2} = Sprites.attach_session(sprite, session_id, owner: self(), stdin: true)
  IO.inspect(cmd2, label: "attach ok")

  # === Phase 6: wait for AFTER + EXIT_OK + exit ===
  # If detach is real, we should see AFTER + EXIT_OK arrive within ~20s.
  IO.puts("\n=== phase 6: collect post-reattach output for 30s ===")

  collect = fn collect, deadline, acc ->
    timeout = max(0, deadline - System.monotonic_time(:millisecond))

    receive do
      {:stdout, %{ref: ref}, data} when ref == cmd2.ref ->
        bin = IO.iodata_to_binary(data)
        IO.puts("# stdout: #{inspect(bin)}")
        collect.(collect, deadline, [bin | acc])

      {:stderr, %{ref: ref}, data} when ref == cmd2.ref ->
        IO.puts("# stderr: #{inspect(data)}")
        collect.(collect, deadline, acc)

      {:exit, %{ref: ref}, code} when ref == cmd2.ref ->
        IO.puts("# exit: #{code}")
        Enum.reverse([{:exit, code} | acc])

      {:error, _, reason} ->
        IO.inspect(reason, label: "error")
        Enum.reverse(acc)

      msg ->
        IO.inspect(msg, label: "other-msg")
        collect.(collect, deadline, acc)
    after
      timeout -> Enum.reverse(acc)
    end
  end

  deadline = System.monotonic_time(:millisecond) + 30_000
  result = collect.(collect, deadline, [])

  IO.puts("\n=== verdict ===")
  joined = result |> Enum.reject(&is_tuple/1) |> Enum.join("")
  exited? = Enum.any?(result, &match?({:exit, _}, &1))

  cond do
    String.contains?(joined, "AFTER") and exited? ->
      IO.puts("PASS — sprites supports detachable + reattach. AFTER arrived after disconnect.")

    String.contains?(joined, "AFTER") ->
      IO.puts("PARTIAL — saw AFTER but no exit message.")

    exited? ->
      IO.puts("FAIL — saw exit but no AFTER. Process likely died at disconnect.")

    true ->
      IO.puts("FAIL — no AFTER, no exit. Either still running silently or process died.")
  end
after
  destroy.()
end
