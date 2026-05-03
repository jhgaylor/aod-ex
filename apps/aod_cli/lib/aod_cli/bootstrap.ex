defmodule AodCli.Bootstrap do
  @moduledoc """
  OTP Application module that runs the CLI when started.

  In a Burrito-wrapped release, the bin script invokes the OTP app
  via `bin/aod start` (or `daemon`). For the CLI use case we don't
  want a long-running server; we want to run `AodCli.main/1` with
  the args the user passed and exit.

  Burrito captures argv via `Burrito.Util.Args.argv/0`. When running
  the binary outside Burrito (e.g. inside a vanilla `mix release`
  invocation), `System.argv/0` is the fallback.

  We detach the actual work into a Task so the Application start
  callback can return `{:ok, pid}` cleanly. The Task halts the VM
  on completion.
  """

  use Application

  @impl Application
  def start(_type, _args) do
    if cli_release?() do
      # Burrito's documented pattern: do the work in start/2 directly
      # and System.halt at the end. The earlier Task-supervisor approach
      # could deadlock because Application.start was returning before
      # the Task got scheduled cleanly.
      args = read_argv()

      try do
        AodCli.main(args)
        System.halt(0)
      rescue
        e ->
          IO.puts(:stderr, "aod: " <> Exception.message(e))
          System.halt(1)
      end
    else
      # `mix test`, `iex -S mix`, the server release (which depends on
      # aod_cli for AodCli.Substitution but isn't running the CLI), etc.
      Supervisor.start_link([], strategy: :one_for_one, name: AodCli.Bootstrap.Sup)
    end
  end

  # Three contexts to distinguish:
  #   * dev/test/iex      — Mix is loaded as an OTP app
  #   * CLI release       — Mix not loaded; agent_on_demand not loaded
  #   * server release    — Mix not loaded; agent_on_demand IS loaded
  #     (the server release bundles aod_cli for AodCli.Substitution)
  # We only run main in the CLI release.
  #
  # Burrito doesn't propagate `RELEASE_NAME` to the runtime env, so an
  # env-var or config-flag gate (set in runtime.exs) ends up dormant.
  # Inspecting loaded applications works regardless.
  defp cli_release? do
    Application.spec(:mix) == nil and Application.spec(:agent_on_demand) == nil
  end

  defp read_argv do
    # `apply/3` instead of a direct call so the compiler doesn't warn
    # when Burrito (a build-time-only dep) isn't loaded for a plain
    # `mix compile`.
    burrito = Burrito.Util.Args

    if Code.ensure_loaded?(burrito) and function_exported?(burrito, :argv, 0) do
      apply(burrito, :argv, [])
    else
      System.argv()
    end
  end
end
