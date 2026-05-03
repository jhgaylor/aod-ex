defmodule AodCli.ApplyTest do
  use ExUnit.Case, async: true

  alias AodCli.Apply

  describe "build_apply_vars/1" do
    setup do
      # Snapshot keys we mutate so tests are isolated.
      keys = ~w(AOD_TEST_GH_PAT AOD_TEST_OVERLAY)
      saved = Map.new(keys, &{&1, System.get_env(&1)})

      on_exit(fn ->
        Enum.each(saved, fn
          {k, nil} -> System.delete_env(k)
          {k, v} -> System.put_env(k, v)
        end)
      end)

      :ok
    end

    test "merges System env vars with --var flag values" do
      System.put_env("AOD_TEST_GH_PAT", "ghp_from_env")

      vars = Apply.build_apply_vars(["AOD_TEST_OVERLAY=overlay_value"])

      assert vars["AOD_TEST_GH_PAT"] == "ghp_from_env"
      assert vars["AOD_TEST_OVERLAY"] == "overlay_value"
    end

    test "--var wins over System env on key collision" do
      System.put_env("AOD_TEST_GH_PAT", "ghp_from_env")

      vars = Apply.build_apply_vars(["AOD_TEST_GH_PAT=ghp_from_flag"])

      assert vars["AOD_TEST_GH_PAT"] == "ghp_from_flag"
    end

    test "--var values containing `=` are preserved" do
      vars = Apply.build_apply_vars(["TOKEN=k=v=w"])
      assert vars["TOKEN"] == "k=v=w"
    end

    test "no --var flags returns just the env" do
      vars = Apply.build_apply_vars([])
      # PATH is essentially always set; sanity check the env is being read.
      assert is_binary(vars["PATH"])
    end
  end
end
