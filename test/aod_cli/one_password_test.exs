defmodule AodCli.OnePasswordTest do
  use ExUnit.Case, async: true

  alias AodCli.OnePassword

  describe "ref?/1" do
    test "true for op:// strings" do
      assert OnePassword.ref?("op://Personal/GitHub/token")
    end

    test "false for everything else" do
      refute OnePassword.ref?("ghp_literal")
      refute OnePassword.ref?("${GITHUB_TOKEN}")
      refute OnePassword.ref?(nil)
      refute OnePassword.ref?(42)
      refute OnePassword.ref?(%{})
    end
  end

  describe "read/2" do
    test "returns {:ok, value} on success" do
      opts = [
        find_executable: fn "op" -> "/usr/local/bin/op" end,
        cmd: fn _path, _args, _opts -> {"ghp_resolved", 0} end
      ]

      assert {:ok, "ghp_resolved"} =
               OnePassword.read("op://Personal/GitHub/token", opts)
    end

    test "passes the ref through to op read --no-newline" do
      opts = [
        find_executable: fn "op" -> "/op" end,
        cmd: fn _path, args, _opts ->
          assert args == ["read", "--no-newline", "op://Vault/Item/field"]
          {"value", 0}
        end
      ]

      assert {:ok, "value"} = OnePassword.read("op://Vault/Item/field", opts)
    end

    test "captures stderr by combining it with stdout" do
      opts = [
        find_executable: fn "op" -> "/op" end,
        cmd: fn _path, _args, cmd_opts ->
          assert cmd_opts[:stderr_to_stdout] == true
          {"value", 0}
        end
      ]

      assert {:ok, "value"} = OnePassword.read("op://V/I/f", opts)
    end

    test "returns {:error, :op_not_installed} when op is missing" do
      opts = [find_executable: fn "op" -> nil end]
      assert {:error, :op_not_installed} = OnePassword.read("op://V/I/f", opts)
    end

    test "returns {:error, {:op_failed, msg}} on non-zero exit, trimming whitespace" do
      opts = [
        find_executable: fn "op" -> "/op" end,
        cmd: fn _, _, _ ->
          {"[ERROR] session expired, please run `op signin`\n", 1}
        end
      ]

      assert {:error, {:op_failed, "[ERROR] session expired, please run `op signin`"}} =
               OnePassword.read("op://V/I/f", opts)
    end
  end

  describe "format_error/1" do
    test "op_not_installed has install instructions" do
      msg = OnePassword.format_error(:op_not_installed)
      assert msg =~ "1Password CLI"
      assert msg =~ "developer.1password.com"
    end

    test "op_failed surfaces the captured output" do
      assert OnePassword.format_error({:op_failed, "session expired"}) ==
               "session expired"
    end

    test "op_failed with empty output falls back to a generic message" do
      assert OnePassword.format_error({:op_failed, ""}) =~ "non-zero"
    end
  end
end
