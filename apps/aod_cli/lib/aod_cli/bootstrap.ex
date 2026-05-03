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
    children =
      if release_mode?() do
        [
          Supervisor.child_spec(
            {Task, fn -> run_and_halt() end},
            id: AodCli.Bootstrap.Runner,
            restart: :temporary
          )
        ]
      else
        # `mix test`, `iex -S mix`, etc. — just be a loaded OTP app,
        # don't auto-run the CLI. The CLI is invoked explicitly via
        # `mix run -e "AodCli.main([...])"` or the escript build.
        []
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: AodCli.Bootstrap.Sup)
  end

  # In a Burrito-wrapped or `mix release` binary, Mix isn't included.
  # In dev/test/iex, Mix is loaded.
  defp release_mode? do
    Application.spec(:mix) == nil
  end

  defp run_and_halt do
    args = read_argv()

    try do
      AodCli.main(args)
      System.halt(0)
    rescue
      e ->
        IO.puts(:stderr, "aod: " <> Exception.message(e))
        System.halt(1)
    end
  end

  defp read_argv do
    # `apply/3` instead of a direct call so the compiler doesn't warn
    # when Burrito (a build-time-only dep) isn't loaded yet during a
    # plain `mix compile`.
    burrito = Burrito.Util.Args

    if Code.ensure_loaded?(burrito) and function_exported?(burrito, :argv, 0) do
      apply(burrito, :argv, [])
    else
      System.argv()
    end
  end
end
