defmodule AgentOnDemand.EnvironmentsTest do
  use AgentOnDemand.DataCase, async: true

  alias AgentOnDemand.Environments
  alias AgentOnDemand.Environments.Secret

  describe "environments CRUD" do
    test "list returns inserted envs" do
      a = insert_env(%{"name" => "first"})
      b = insert_env(%{"name" => "second"})

      ids = Environments.list_environments() |> Enum.map(& &1.id)
      assert a.id in ids
      assert b.id in ids
    end

    test "get_environment returns nil for unknown id" do
      assert Environments.get_environment(Ecto.UUID.generate()) == nil
    end

    test "update changes attributes" do
      env = insert_env(%{"name" => "before"})
      {:ok, env} = Environments.update_environment(env, %{"name" => "after"})
      assert env.name == "after"
    end

    test "delete cascades secrets via FK" do
      env = insert_env()
      _s = insert_secret(env, %{"key" => "WILL_GO"})
      {:ok, _} = Environments.delete_environment(env)
      assert Environments.get_environment(env.id) == nil
      # And the secret is gone too:
      assert Repo.aggregate(Secret, :count, :id) == 0
    end
  end

  describe "secrets" do
    setup do
      {:ok, env: insert_env()}
    end

    test "upsert_secret creates if missing", %{env: env} do
      {:ok, secret} = Environments.upsert_secret(env, %{"key" => "K", "value" => "v1"})
      assert secret.id
      assert {:ok, "v1"} = Secret.decrypt(secret)
    end

    test "upsert_secret updates if present", %{env: env} do
      {:ok, _} = Environments.upsert_secret(env, %{"key" => "K", "value" => "v1"})
      {:ok, updated} = Environments.upsert_secret(env, %{"key" => "K", "value" => "v2"})
      assert {:ok, "v2"} = Secret.decrypt(updated)
      assert length(Environments.list_secrets(env)) == 1
    end

    test "list_secrets is alphabetical by key", %{env: env} do
      insert_secret(env, %{"key" => "BANANA"})
      insert_secret(env, %{"key" => "APPLE"})
      keys = Environments.list_secrets(env) |> Enum.map(& &1.key)
      assert keys == Enum.sort(keys)
    end

    test "delete_secret removes one row", %{env: env} do
      s = insert_secret(env, %{"key" => "GONE"})
      {:ok, _} = Environments.delete_secret(s)
      assert Environments.list_secrets(env) == []
    end

    test "decrypted_env returns plaintext map", %{env: env} do
      insert_secret(env, %{"key" => "GITHUB_TOKEN", "value" => "ghp_abc"})
      insert_secret(env, %{"key" => "API_KEY", "value" => "sk_xyz"})
      assert %{"GITHUB_TOKEN" => "ghp_abc", "API_KEY" => "sk_xyz"} = Environments.decrypted_env(env)
    end

    test "decrypted_env returns empty for env with no secrets", %{env: env} do
      assert Environments.decrypted_env(env) == %{}
    end
  end
end
