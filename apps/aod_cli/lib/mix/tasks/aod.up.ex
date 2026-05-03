defmodule Mix.Tasks.Aod.Up do
  @moduledoc """
  Thin wrapper around `AodCli.Up.dispatch/1`. Both `mix aod.up` and
  `./aod up` (from the released binary) hit the same code path. See
  `AodCli.Up` for the full docs.

  Usage:
      SPRITES_TOKEN=... mix aod.up
      SPRITES_TOKEN=... mix aod.up --name my-aod
      SPRITES_TOKEN=... mix aod.up --name my-aod --release v0.1.0

  Tear down: `mix aod.down <name>`.
  """
  use Mix.Task

  @shortdoc "Deploy AoD to a Sprite (or upgrade in place)"

  @impl Mix.Task
  def run(args) do
    # `--destroy <name>` is a deprecated path that used to live here.
    # Strip it and forward to AodCli.Down so existing scripts keep
    # working with one warning.
    case extract_destroy(args) do
      {:destroy, name} ->
        IO.puts(
          :stderr,
          "warning: `mix aod.up --destroy <name>` is deprecated; use `mix aod.down <name>` instead."
        )

        AodCli.Down.dispatch([name])

      :no_destroy ->
        AodCli.Up.dispatch(args)
    end
  end

  defp extract_destroy(args) do
    case OptionParser.parse(args, strict: [destroy: :string], allow_nonexistent_atoms: true) do
      {[destroy: name], _, _} when is_binary(name) -> {:destroy, name}
      _ -> :no_destroy
    end
  end
end
