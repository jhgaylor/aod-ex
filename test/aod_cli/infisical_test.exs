defmodule AodCli.InfisicalTest do
  use ExUnit.Case, async: true

  alias AodCli.Infisical

  describe "ref?/1" do
    test "true for infisical:// strings" do
      assert Infisical.ref?("infisical://abc/prod/MY_KEY")
    end

    test "false for everything else" do
      refute Infisical.ref?("op://Personal/GitHub/token")
      refute Infisical.ref?("bws://abc-123")
      refute Infisical.ref?("ghp_literal")
      refute Infisical.ref?(nil)
      refute Infisical.ref?(42)
    end
  end

  describe "read/2 — happy path arg construction" do
    test "explicit project + env + name (no path) defaults path to /" do
      capture =
        fn _path, args, _opts ->
          send(self(), {:args, args})
          {"the-value\n", 0}
        end

      opts = [find_executable: fn "infisical" -> "/inf" end, cmd: capture]
      assert {:ok, "the-value"} = Infisical.read("infisical://abc/prod/DATABASE_URL", opts)

      assert_received {:args, args}

      assert args == [
               "secrets",
               "get",
               "DATABASE_URL",
               "--env=prod",
               "--path=/",
               "--plain",
               "--projectId=abc"
             ]
    end

    test "explicit project + env + path + name" do
      capture = fn _, args, _ -> send(self(), {:args, args}) && {"v", 0} end
      opts = [find_executable: fn "infisical" -> "/inf" end, cmd: capture]

      assert {:ok, "v"} =
               Infisical.read("infisical://abc/prod/api/DATABASE_URL", opts)

      assert_received {:args, args}
      assert "--path=/api" in args
      assert "--projectId=abc" in args
    end

    test "deeply nested path" do
      capture = fn _, args, _ -> send(self(), {:args, args}) && {"v", 0} end
      opts = [find_executable: fn "infisical" -> "/inf" end, cmd: capture]

      assert {:ok, "v"} =
               Infisical.read("infisical://abc/prod/api/v2/internal/DATABASE_URL", opts)

      assert_received {:args, args}
      assert "--path=/api/v2/internal" in args
    end

    test "empty project segment falls through (no --projectId flag)" do
      capture = fn _, args, _ -> send(self(), {:args, args}) && {"v", 0} end
      opts = [find_executable: fn "infisical" -> "/inf" end, cmd: capture]

      assert {:ok, "v"} = Infisical.read("infisical:///prod/DATABASE_URL", opts)

      assert_received {:args, args}
      refute Enum.any?(args, &String.starts_with?(&1, "--projectId="))
      assert "--env=prod" in args
      assert "--path=/" in args
    end

    test "empty project segment + nested path" do
      capture = fn _, args, _ -> send(self(), {:args, args}) && {"v", 0} end
      opts = [find_executable: fn "infisical" -> "/inf" end, cmd: capture]

      assert {:ok, "v"} = Infisical.read("infisical:///prod/api/MY_KEY", opts)

      assert_received {:args, args}
      refute Enum.any?(args, &String.starts_with?(&1, "--projectId="))
      assert "--path=/api" in args
    end

    test "trims trailing newline from --plain output" do
      opts = [
        find_executable: fn "infisical" -> "/inf" end,
        cmd: fn _, _, _ -> {"my-value\n", 0} end
      ]

      assert {:ok, "my-value"} =
               Infisical.read("infisical://abc/prod/MY_KEY", opts)
    end

    test "captures stderr by combining it with stdout" do
      opts = [
        find_executable: fn "infisical" -> "/inf" end,
        cmd: fn _, _, cmd_opts ->
          assert cmd_opts[:stderr_to_stdout] == true
          {"v", 0}
        end
      ]

      assert {:ok, "v"} = Infisical.read("infisical://abc/prod/MY_KEY", opts)
    end
  end

  describe "read/2 — error paths" do
    test "infisical not installed" do
      opts = [find_executable: fn "infisical" -> nil end]
      assert {:error, :infisical_not_installed} = Infisical.read("infisical://abc/prod/K", opts)
    end

    test "non-zero exit, trimming whitespace" do
      opts = [
        find_executable: fn "infisical" -> "/inf" end,
        cmd: fn _, _, _ -> {"Error: secret not found\n", 1} end
      ]

      assert {:error, {:infisical_failed, "Error: secret not found"}} =
               Infisical.read("infisical://abc/prod/MISSING", opts)
    end

    test "URI with too few segments" do
      opts = [find_executable: fn "infisical" -> "/inf" end]
      # Only one segment after infisical:// — can't form even env+name.
      assert {:error, {:invalid_ref, _}} = Infisical.read("infisical://just-one", opts)
    end

    test "URI missing env" do
      opts = [find_executable: fn "infisical" -> "/inf" end]
      assert {:error, {:invalid_ref, _}} = Infisical.read("infisical://abc//MY_KEY", opts)
    end

    test "URI with empty middle path segment" do
      opts = [find_executable: fn "infisical" -> "/inf" end]

      assert {:error, {:invalid_ref, _}} =
               Infisical.read("infisical://abc/prod/api//MY_KEY", opts)
    end

    test "URI with empty trailing name segment" do
      opts = [find_executable: fn "infisical" -> "/inf" end]
      assert {:error, {:invalid_ref, _}} = Infisical.read("infisical://abc/prod/api/", opts)
    end
  end

  describe "format_error/1" do
    test "infisical_not_installed has install instructions" do
      msg = Infisical.format_error(:infisical_not_installed)
      assert msg =~ "Infisical"
      assert msg =~ "infisical.com"
    end

    test "invalid_ref includes the reason" do
      msg = Infisical.format_error({:invalid_ref, "missing env"})
      assert msg =~ "invalid infisical://"
      assert msg =~ "missing env"
    end

    test "infisical_failed surfaces output" do
      assert Infisical.format_error({:infisical_failed, "secret not found"}) ==
               "secret not found"
    end

    test "infisical_failed with empty output falls back to a generic message" do
      assert Infisical.format_error({:infisical_failed, ""}) =~ "non-zero"
    end
  end
end
