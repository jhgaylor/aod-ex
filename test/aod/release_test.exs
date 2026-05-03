defmodule AoD.ReleaseTest do
  use ExUnit.Case, async: true

  alias AoD.Release

  # We can't easily run a full `mix release` in CI, but we *can*
  # exercise the dispatcher shell script by writing it next to a stub
  # bin/aod-release that just echoes its args. That proves the
  # case/forward/escape logic without needing Burrito or Zig.

  setup do
    tmp = Path.join([System.tmp_dir!(), "aod-rel-test-#{System.unique_integer([:positive])}"])
    bin = Path.join(tmp, "bin")
    File.mkdir_p!(bin)

    File.write!(Path.join(bin, "aod"), Release.dispatcher_script())
    File.chmod!(Path.join(bin, "aod"), 0o755)

    # Stub release binary that prints the args it received, one per
    # line, so we can assert what the dispatcher forwarded.
    stub = ~S"""
    #!/bin/sh
    for arg in "$@"; do
      printf '%s\n' "$arg"
    done
    """

    File.write!(Path.join(bin, "aod-release"), stub)
    File.chmod!(Path.join(bin, "aod-release"), 0o755)

    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, bin: bin}
  end

  defp run(bin, args) do
    {output, code} =
      System.cmd(Path.join(bin, "aod"), args, stderr_to_stdout: true)

    {String.trim_trailing(output, "\n"), code}
  end

  describe "standard release subcommands" do
    test "start is forwarded as-is", %{bin: bin} do
      assert {"start", 0} = run(bin, ["start"])
    end

    test "daemon is forwarded as-is", %{bin: bin} do
      assert {"daemon", 0} = run(bin, ["daemon"])
    end

    test "eval with an inline expression is forwarded as-is", %{bin: bin} do
      # Important: when the operator/sprite already passes `eval`,
      # we must not double-wrap it.
      assert {"eval\nMyApp.do_thing()", 0} = run(bin, ["eval", "MyApp.do_thing()"])
    end

    test "no args forwards an empty invocation", %{bin: bin} do
      assert {"", 0} = run(bin, [])
    end
  end

  describe "CLI dispatch (non-standard args)" do
    test "wraps args into AodCli.main([...]) eval expression", %{bin: bin} do
      assert {output, 0} = run(bin, ["conv", "list"])

      lines = String.split(output, "\n")
      assert ["eval", expr] = lines
      assert expr == ~s|AodCli.main(["conv", "list"])|
    end

    test "single arg with no value", %{bin: bin} do
      assert {output, 0} = run(bin, ["foo"])
      assert ["eval", expr] = String.split(output, "\n")
      assert expr == ~s|AodCli.main(["foo"])|
    end

    test "args with spaces stay as a single list element", %{bin: bin} do
      assert {output, 0} = run(bin, ["run", "echo-bot", "-p", "say hi please"])
      assert ["eval", expr] = String.split(output, "\n")
      assert expr == ~s|AodCli.main(["run", "echo-bot", "-p", "say hi please"])|
    end

    test "args containing double quotes are escaped", %{bin: bin} do
      assert {output, 0} = run(bin, ["echo", ~s(hello "world")])
      assert ["eval", expr] = String.split(output, "\n")
      assert expr == ~s|AodCli.main(["echo", "hello \\"world\\""])|
    end

    test "args containing backslashes are escaped", %{bin: bin} do
      assert {output, 0} = run(bin, ["echo", ~s(c:\\path)])
      assert ["eval", expr] = String.split(output, "\n")
      assert expr == ~s|AodCli.main(["echo", "c:\\\\path"])|
    end

    test "argv flags pass through (--vault, etc.)", %{bin: bin} do
      assert {output, 0} = run(bin, ["run", "agent", "--vault", "alice", "-p", "hi"])
      assert ["eval", expr] = String.split(output, "\n")

      assert expr ==
               ~s|AodCli.main(["run", "agent", "--vault", "alice", "-p", "hi"])|
    end
  end
end
