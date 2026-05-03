defmodule AodCli.BitwardenTest do
  use ExUnit.Case, async: true

  alias AodCli.Bitwarden

  describe "ref?/1" do
    test "true for bws:// strings" do
      assert Bitwarden.ref?("bws://be8e0ad8-1234-5678-90ab-cdef01234567")
    end

    test "false for everything else" do
      refute Bitwarden.ref?("op://Personal/GitHub/token")
      refute Bitwarden.ref?("ghp_literal")
      refute Bitwarden.ref?("${BWS_TOKEN}")
      refute Bitwarden.ref?(nil)
      refute Bitwarden.ref?(42)
    end
  end

  describe "read/2" do
    test "returns {:ok, value} on success, parsing the .value field of bws JSON" do
      payload = ~s({"object":"secret","id":"u","key":"GH","value":"ghp_resolved","note":""})

      opts = [
        find_executable: fn "bws" -> "/opt/bin/bws" end,
        cmd: fn _path, _args, _opts -> {payload, 0} end
      ]

      assert {:ok, "ghp_resolved"} =
               Bitwarden.read("bws://be8e0ad8-1234-5678-90ab-cdef01234567", opts)
    end

    test "passes the UUID through to bws secret get" do
      opts = [
        find_executable: fn "bws" -> "/bws" end,
        cmd: fn _path, args, _opts ->
          assert args == ["secret", "get", "abc-123"]
          {~s({"value":"x"}), 0}
        end
      ]

      assert {:ok, "x"} = Bitwarden.read("bws://abc-123", opts)
    end

    test "captures stderr by combining it with stdout" do
      opts = [
        find_executable: fn "bws" -> "/bws" end,
        cmd: fn _path, _args, cmd_opts ->
          assert cmd_opts[:stderr_to_stdout] == true
          {~s({"value":"x"}), 0}
        end
      ]

      assert {:ok, "x"} = Bitwarden.read("bws://abc", opts)
    end

    test "returns {:error, :bws_not_installed} when bws is missing" do
      opts = [find_executable: fn "bws" -> nil end]
      assert {:error, :bws_not_installed} = Bitwarden.read("bws://abc-123", opts)
    end

    test "returns {:error, :empty_ref} when UUID is missing" do
      assert {:error, :empty_ref} = Bitwarden.read("bws://", [])
    end

    test "returns {:error, {:bws_failed, msg}} on non-zero exit, trimming whitespace" do
      opts = [
        find_executable: fn "bws" -> "/bws" end,
        cmd: fn _, _, _ -> {"Error: invalid access token\n", 1} end
      ]

      assert {:error, {:bws_failed, "Error: invalid access token"}} =
               Bitwarden.read("bws://abc", opts)
    end

    test "returns :bws_unexpected_output on missing value field" do
      opts = [
        find_executable: fn "bws" -> "/bws" end,
        cmd: fn _, _, _ -> {~s({"object":"secret","id":"u"}), 0} end
      ]

      assert {:error, {:bws_unexpected_output, msg}} = Bitwarden.read("bws://abc", opts)
      assert msg =~ "value"
    end

    test "returns :bws_unexpected_output on malformed JSON" do
      opts = [
        find_executable: fn "bws" -> "/bws" end,
        cmd: fn _, _, _ -> {"not json at all", 0} end
      ]

      assert {:error, {:bws_unexpected_output, msg}} = Bitwarden.read("bws://abc", opts)
      assert msg =~ "JSON"
    end
  end

  describe "format_error/1" do
    test "bws_not_installed has install instructions" do
      msg = Bitwarden.format_error(:bws_not_installed)
      assert msg =~ "Bitwarden"
      assert msg =~ "bitwarden.com"
    end

    test "empty_ref" do
      assert Bitwarden.format_error(:empty_ref) =~ "missing the UUID"
    end

    test "bws_failed surfaces captured output" do
      assert Bitwarden.format_error({:bws_failed, "session expired"}) ==
               "session expired"
    end

    test "bws_failed with empty output falls back to a generic message" do
      assert Bitwarden.format_error({:bws_failed, ""}) =~ "non-zero"
    end

    test "bws_unexpected_output describes the parsing failure" do
      msg = Bitwarden.format_error({:bws_unexpected_output, "JSON had no value field"})
      assert msg =~ "unexpected bws output"
      assert msg =~ "value"
    end
  end
end
