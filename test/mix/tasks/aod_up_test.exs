defmodule Mix.Tasks.Aod.UpTest do
  use ExUnit.Case, async: true

  # Round-trip the start.sh writer + parser. The mix task itself isn't
  # otherwise unit-tested (it's a thin shell over Sprites HTTP), but
  # this parser is what makes upgrade-in-place safe — if it breaks,
  # an upgrade silently swaps in a binary that can't decrypt the DB.

  defp run_round_trip(env) do
    script =
      env
      |> Enum.map(fn {k, v} -> "export #{k}=#{shell_quote(v)}" end)
      |> Enum.join("\n")

    parse_start_sh(script)
  end

  # Mirrors the task's private fns. Kept here so we round-trip
  # against the same exact strings the task would produce.
  defp shell_quote(value) do
    "'" <> String.replace(value, "'", ~S('"'"')) <> "'"
  end

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

  describe "start.sh round-trip" do
    test "preserves simple values" do
      env = [{"ADMIN_TOKEN", "abc123"}, {"PORT", "4000"}]
      assert run_round_trip(env) == env
    end

    test "preserves values with spaces" do
      env = [{"PHX_HOST", "my host with spaces"}]
      assert run_round_trip(env) == env
    end

    test "preserves values with embedded single quotes" do
      env = [{"FUNNY", "it's a value with 'quotes'"}]
      assert run_round_trip(env) == env
    end

    test "preserves URL-shaped values" do
      env = [{"AOD_PUBLIC_URL", "https://aod-123-region.sprites.app:4000/"}]
      assert run_round_trip(env) == env
    end

    test "preserves base64 secrets" do
      env = [
        {"SECRETS_KEY", "dGhpcy1pcy1hLWZha2Uta2V5LXdpdGgtcGFkZGluZw=="},
        {"SECRET_KEY_BASE", "deadbeef" <> String.duplicate("a", 120)}
      ]

      assert run_round_trip(env) == env
    end

    test "skips lines that aren't `export KEY=val` (shebang, blank, set -eu, exec)" do
      script = """
      #!/bin/sh
      set -eu
      export ADMIN_TOKEN='abc'

      exec /opt/aod/aod start
      """

      assert parse_start_sh(script) == [{"ADMIN_TOKEN", "abc"}]
    end
  end
end
