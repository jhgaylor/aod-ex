defmodule AodCli.UpTest do
  use ExUnit.Case, async: true

  alias AodCli.Up

  # Round-trip the start.sh writer + parser. We can't unit-test the
  # full deploy/upgrade flow (it's all Sprites HTTP), but this
  # parser is what makes upgrade-in-place safe — if it breaks, an
  # upgrade silently swaps in a binary that can't decrypt the DB.

  defp round_trip(env) do
    script =
      env
      |> Enum.map(fn {k, v} -> "export #{k}=#{Up.shell_quote(v)}" end)
      |> Enum.join("\n")

    Up.parse_start_sh(script)
  end

  describe "start.sh round-trip" do
    test "preserves simple values" do
      env = [{"ADMIN_TOKEN", "abc123"}, {"PORT", "4000"}]
      assert round_trip(env) == env
    end

    test "preserves values with spaces" do
      env = [{"PHX_HOST", "my host with spaces"}]
      assert round_trip(env) == env
    end

    test "preserves values with embedded single quotes" do
      env = [{"FUNNY", "it's a value with 'quotes'"}]
      assert round_trip(env) == env
    end

    test "preserves URL-shaped values" do
      env = [{"AOD_PUBLIC_URL", "https://aod-123-region.sprites.app:4000/"}]
      assert round_trip(env) == env
    end

    test "preserves base64 secrets" do
      env = [
        {"SECRETS_KEY", "dGhpcy1pcy1hLWZha2Uta2V5LXdpdGgtcGFkZGluZw=="},
        {"SECRET_KEY_BASE", "deadbeef" <> String.duplicate("a", 120)}
      ]

      assert round_trip(env) == env
    end

    test "skips lines that aren't `export KEY=val` (shebang, blank, set -eu, exec)" do
      script = """
      #!/bin/sh
      set -eu
      export ADMIN_TOKEN='abc'

      exec /opt/aod/aod start
      """

      assert Up.parse_start_sh(script) == [{"ADMIN_TOKEN", "abc"}]
    end
  end
end
