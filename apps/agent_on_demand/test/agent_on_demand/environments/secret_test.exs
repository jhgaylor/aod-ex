defmodule AgentOnDemand.Environments.SecretTest do
  use AgentOnDemand.DataCase, async: false

  alias AgentOnDemand.Environments.Secret

  describe "changeset" do
    setup do
      {:ok, env: insert_env()}
    end

    test "requires key, value, environment_id", %{env: _env} do
      cs = Secret.changeset(%Secret{}, %{})
      refute cs.valid?
      errors = errors_on(cs)
      assert errors[:key]
      assert errors[:value]
      assert errors[:environment_id]
    end

    test "rejects lowercase key", %{env: env} do
      cs =
        Secret.changeset(%Secret{}, %{
          "key" => "lowercase",
          "value" => "v",
          "environment_id" => env.id
        })

      refute cs.valid?
      assert "must be UPPER_SNAKE_CASE" in errors_on(cs).key
    end

    test "rejects key starting with digit", %{env: env} do
      cs =
        Secret.changeset(%Secret{}, %{
          "key" => "1FOO",
          "value" => "v",
          "environment_id" => env.id
        })

      refute cs.valid?
    end

    test "accepts UPPER_SNAKE_CASE", %{env: env} do
      cs =
        Secret.changeset(%Secret{}, %{
          "key" => "GITHUB_TOKEN",
          "value" => "v",
          "environment_id" => env.id
        })

      assert cs.valid?
    end

    test "encrypts value into value_ciphertext on insert", %{env: env} do
      secret = insert_secret(env, %{"value" => "plain-secret"})
      assert is_binary(secret.value_ciphertext)
      assert byte_size(secret.value_ciphertext) > 28
      assert {:ok, "plain-secret"} = Secret.decrypt(secret)
    end

    test "round trips multiple distinct values", %{env: env} do
      a = insert_secret(env, %{"key" => "ALPHA", "value" => "a-value"})
      b = insert_secret(env, %{"key" => "BETA", "value" => "b-value"})
      assert {:ok, "a-value"} = Secret.decrypt(a)
      assert {:ok, "b-value"} = Secret.decrypt(b)
    end

    test "unique on (environment_id, key)", %{env: env} do
      insert_secret(env, %{"key" => "DUP"})
      # Direct insert (not upsert) to assert the constraint fires.
      cs =
        Secret.changeset(%Secret{}, %{"key" => "DUP", "value" => "v", "environment_id" => env.id})

      assert {:error, %{errors: errors}} = AgentOnDemand.Repo.insert(cs)
      assert Keyword.has_key?(errors, :environment_id) or Keyword.has_key?(errors, :key)
    end
  end
end
