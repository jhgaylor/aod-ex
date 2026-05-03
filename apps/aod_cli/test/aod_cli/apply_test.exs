defmodule AodCli.ApplyTest do
  use ExUnit.Case, async: false

  alias AodCli.Apply

  defp tmpdir!(name) do
    path =
      Path.join([System.tmp_dir!(), "aod-apply-test-#{System.unique_integer([:positive])}", name])

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(Path.dirname(path)) end)
    path
  end

  defp write!(path, content) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    path
  end

  describe "aod_resource?/1" do
    test "true when both apiVersion and kind are present" do
      assert Apply.aod_resource?(%{"apiVersion" => "aod/v1", "kind" => "Agent"})
    end

    test "false when apiVersion is missing" do
      refute Apply.aod_resource?(%{"kind" => "Agent"})
    end

    test "false when kind is missing" do
      refute Apply.aod_resource?(%{"apiVersion" => "aod/v1"})
    end

    test "false for non-maps" do
      refute Apply.aod_resource?(nil)
      refute Apply.aod_resource?("just a string")
      refute Apply.aod_resource?(42)
    end
  end

  describe "read_docs!/1 — single file" do
    test "returns the parsed docs that carry apiVersion + kind" do
      tmp = tmpdir!("file")
      file = Path.join(tmp, "manifest.yml")

      write!(file, """
      ---
      apiVersion: aod/v1
      kind: Environment
      metadata:
        name: a
      ---
      apiVersion: aod/v1
      kind: Agent
      metadata:
        name: b
      """)

      docs = Apply.read_docs!(file)
      assert length(docs) == 2
      assert Enum.map(docs, & &1["kind"]) == ["Environment", "Agent"]
    end

    test "filters out docs that lack apiVersion or kind" do
      tmp = tmpdir!("file")
      file = Path.join(tmp, "manifest.yml")

      write!(file, """
      ---
      apiVersion: aod/v1
      kind: Environment
      metadata:
        name: keep
      ---
      # bare data with no front matter — should be ignored
      foo: bar
      ---
      apiVersion: aod/v1
      # missing kind — should be ignored
      metadata:
        name: skip
      """)

      docs = Apply.read_docs!(file)
      assert length(docs) == 1
      assert hd(docs)["metadata"]["name"] == "keep"
    end
  end

  describe "read_docs!/1 — directory" do
    test "walks recursively and concatenates docs from all .yml/.yaml files" do
      tmp = tmpdir!("dir")

      write!(
        Path.join(tmp, "envs/a.yml"),
        "apiVersion: aod/v1\nkind: Environment\nmetadata:\n  name: a\n"
      )

      write!(
        Path.join(tmp, "envs/b.yaml"),
        "apiVersion: aod/v1\nkind: Environment\nmetadata:\n  name: b\n"
      )

      write!(
        Path.join(tmp, "vaults/v.yml"),
        "apiVersion: aod/v1\nkind: Vault\nmetadata:\n  name: v\n"
      )

      docs = Apply.read_docs!(tmp)
      kinds = Enum.map(docs, & &1["kind"]) |> Enum.sort()
      names = Enum.map(docs, &get_in(&1, ["metadata", "name"])) |> Enum.sort()

      assert kinds == ["Environment", "Environment", "Vault"]
      assert names == ["a", "b", "v"]
    end

    test "ignores files without .yml/.yaml extension" do
      tmp = tmpdir!("ext")

      write!(
        Path.join(tmp, "real.yml"),
        "apiVersion: aod/v1\nkind: Agent\nmetadata:\n  name: real\n"
      )

      write!(Path.join(tmp, "README.md"), "not yaml\n")
      write!(Path.join(tmp, "config.json"), ~s({"foo": "bar"}))
      write!(Path.join(tmp, "notes.txt"), "ignored\n")

      docs = Apply.read_docs!(tmp)
      assert length(docs) == 1
      assert hd(docs)["metadata"]["name"] == "real"
    end

    test "filters out docs in YAML files that lack apiVersion + kind" do
      tmp = tmpdir!("filter")

      # Realistic: a CI workflow yaml drops in but isn't an aod resource.
      write!(Path.join(tmp, ".github/workflows/ci.yml"), """
      name: CI
      on: push
      jobs:
        test:
          runs-on: ubuntu-latest
          steps:
            - uses: actions/checkout@v4
      """)

      write!(Path.join(tmp, "agents/dev.yml"), """
      apiVersion: aod/v1
      kind: Agent
      metadata:
        name: dev
      """)

      docs = Apply.read_docs!(tmp)
      assert length(docs) == 1
      assert hd(docs)["metadata"]["name"] == "dev"
    end

    test "files are processed in alphabetical order" do
      tmp = tmpdir!("order")

      write!(
        Path.join(tmp, "20-second.yml"),
        "apiVersion: aod/v1\nkind: Agent\nmetadata:\n  name: second\n"
      )

      write!(
        Path.join(tmp, "10-first.yml"),
        "apiVersion: aod/v1\nkind: Agent\nmetadata:\n  name: first\n"
      )

      write!(
        Path.join(tmp, "30-third.yml"),
        "apiVersion: aod/v1\nkind: Agent\nmetadata:\n  name: third\n"
      )

      names = Apply.read_docs!(tmp) |> Enum.map(&get_in(&1, ["metadata", "name"]))
      assert names == ["first", "second", "third"]
    end
  end

  describe "resolve_secrets_external_refs/2 — empty-value rule" do
    # A fake resolver that returns whatever value the test set up
    # via the process dictionary, so different tests can exercise
    # different return values without sharing module state.
    defmodule FakeResolver do
      @behaviour AodCli.SecretResolver
      def prefix, do: "fake://"
      def read(ref), do: Process.get({__MODULE__, ref}, {:ok, "default"})
      def format_error(reason), do: "fake error: " <> inspect(reason)
    end

    defp finder(value) do
      if is_binary(value) and String.starts_with?(value, "fake://"), do: FakeResolver, else: nil
    end

    test "treats {:ok, \"\"} from a resolver as :empty_value failure" do
      Process.put({FakeResolver, "fake://k"}, {:ok, ""})

      assert {:error, [{"K", "fake://k", FakeResolver, :empty_value}]} =
               Apply.resolve_secrets_external_refs(%{"K" => "fake://k"}, &finder/1)
    end

    test "non-empty value passes through" do
      Process.put({FakeResolver, "fake://k"}, {:ok, "real-secret"})

      assert {:ok, %{"K" => "real-secret"}} =
               Apply.resolve_secrets_external_refs(%{"K" => "fake://k"}, &finder/1)
    end

    test "literal values (no scheme match) pass through untouched" do
      assert {:ok, %{"K" => "literal-token"}} =
               Apply.resolve_secrets_external_refs(%{"K" => "literal-token"}, &finder/1)
    end

    test "{:error, reason} from resolver is preserved" do
      Process.put({FakeResolver, "fake://k"}, {:error, :some_failure})

      assert {:error, [{"K", "fake://k", FakeResolver, :some_failure}]} =
               Apply.resolve_secrets_external_refs(%{"K" => "fake://k"}, &finder/1)
    end

    test "collects multiple failures across the secrets map in one call" do
      Process.put({FakeResolver, "fake://a"}, {:ok, ""})
      Process.put({FakeResolver, "fake://b"}, {:error, :not_found})
      Process.put({FakeResolver, "fake://c"}, {:ok, "fine"})

      assert {:error, failures} =
               Apply.resolve_secrets_external_refs(
                 %{"A" => "fake://a", "B" => "fake://b", "C" => "fake://c"},
                 &finder/1
               )

      reasons = failures |> Enum.map(fn {_k, _ref, _mod, r} -> r end) |> Enum.sort()
      assert reasons == [:empty_value, :not_found]
    end
  end

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
