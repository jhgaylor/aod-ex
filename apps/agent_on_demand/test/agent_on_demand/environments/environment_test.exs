defmodule AgentOnDemand.Environments.EnvironmentTest do
  use AgentOnDemand.DataCase, async: false

  alias AgentOnDemand.Environments.Environment

  describe "changeset" do
    test "requires name" do
      cs = Environment.changeset(%Environment{}, %{})
      refute cs.valid?
      assert %{name: ["can't be blank"]} = errors_on(cs)
    end

    test "rejects unknown networking_type" do
      cs = Environment.changeset(%Environment{}, %{name: "x", networking_type: "wide-open"})
      refute cs.valid?
      assert "is invalid" in errors_on(cs).networking_type
    end

    test "accepts valid networking_type" do
      for t <- ~w(unrestricted limited) do
        cs = Environment.changeset(%Environment{}, %{name: "x", networking_type: t})
        assert cs.valid?
      end
    end

    test "validates repositories url is https and mount_path absolute" do
      cs =
        Environment.changeset(%Environment{}, %{
          name: "x",
          repositories: [%{"url" => "git://github.com/foo/bar", "mount_path" => "/m"}]
        })

      refute cs.valid?
      assert errors_on(cs)[:repositories]
    end

    test "rejects repositories missing required keys" do
      cs =
        Environment.changeset(%Environment{}, %{
          name: "x",
          repositories: [%{"url" => "https://github.com/foo/bar"}]
        })

      refute cs.valid?
    end

    test "accepts repositories with full spec" do
      cs =
        Environment.changeset(%Environment{}, %{
          name: "x",
          repositories: [
            %{
              "url" => "https://github.com/foo/bar",
              "mount_path" => "/workspace/bar",
              "secret_key" => "GITHUB_TOKEN"
            }
          ]
        })

      assert cs.valid?
    end

    test "rejects relative mount_path" do
      cs =
        Environment.changeset(%Environment{}, %{
          name: "x",
          repositories: [
            %{"url" => "https://github.com/foo/bar", "mount_path" => "relative/path"}
          ]
        })

      refute cs.valid?
    end

    test "enforces unique name" do
      insert_env(%{"name" => "shared"})

      assert {:error, cs} =
               AgentOnDemand.Environments.create_environment(env_attrs(%{"name" => "shared"}))

      assert "has already been taken" in errors_on(cs).name
    end

    test "name length bounded" do
      long = String.duplicate("a", 201)
      cs = Environment.changeset(%Environment{}, %{name: long})
      refute cs.valid?
    end
  end
end
