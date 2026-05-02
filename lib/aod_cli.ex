defmodule AodCli do
  @moduledoc """
  Entry point for the `aod` escript.

  Reads `AOD_BASE_URL` (default http://localhost:4000) and `AOD_TOKEN`
  from the environment.

      aod run <agent> -p "..."          start a conversation, stream until done
      aod conv list [--status RUNNING]  list conversations
      aod conv show <id>                show a single conversation + turns
      aod conv stream <id>              tail an existing conversation's SSE
      aod conv prompt <id> -p "..."     send a follow-up prompt
      aod conv interrupt <id>           stop the running turn (sandbox stays alive)
      aod conv terminate <id>           destroy the sprite (keeps the row)
      aod conv delete <id>              destroy sprite + delete the row + turns
      aod agent list
      aod env list
      aod apply -f <file>               reconcile environments + agents from a YAML manifest

  Pass `--json` to any list/show command to get raw JSON.
  """

  def main(argv) do
    Application.ensure_all_started(:inets)
    Application.ensure_all_started(:ssl)

    case argv do
      ["run" | rest] -> AodCli.Conv.run(rest)
      ["conv" | rest] -> AodCli.Conv.dispatch(rest)
      ["agent" | rest] -> AodCli.Agent.dispatch(rest)
      ["env" | rest] -> AodCli.Env.dispatch(rest)
      ["apply" | rest] -> AodCli.Apply.dispatch(rest)
      ["help"] -> usage()
      ["--help"] -> usage()
      [] -> usage()
      _ -> die("unknown command: #{Enum.join(argv, " ")}")
    end
  end

  defp usage do
    IO.puts(@moduledoc)
  end

  def die(msg) do
    IO.puts(:stderr, "aod: " <> msg)
    System.halt(1)
  end
end
