defmodule AgentOnDemand.VaultsTest do
  use AgentOnDemand.DataCase, async: false

  alias AgentOnDemand.Vaults
  alias AgentOnDemand.Vaults.VaultSecret

  describe "vaults CRUD" do
    test "list returns inserted vaults" do
      a = insert_vault(%{"name" => "first"})
      b = insert_vault(%{"name" => "second"})

      ids = Vaults.list_vaults() |> Enum.map(& &1.id)
      assert a.id in ids
      assert b.id in ids
    end

    test "get_vault returns nil for unknown id" do
      assert Vaults.get_vault(Ecto.UUID.generate()) == nil
    end

    test "get_vault_by_name returns the matching row" do
      v = insert_vault(%{"name" => "alice"})
      assert Vaults.get_vault_by_name("alice").id == v.id
      assert Vaults.get_vault_by_name("nope") == nil
    end

    test "update changes attributes" do
      vault = insert_vault(%{"name" => "before"})
      {:ok, vault} = Vaults.update_vault(vault, %{"name" => "after"})
      assert vault.name == "after"
    end

    test "name uniqueness is enforced" do
      _ = insert_vault(%{"name" => "dup"})
      assert {:error, cs} = Vaults.create_vault(vault_attrs(%{"name" => "dup"}))
      assert "has already been taken" in errors_on(cs).name
    end

    test "delete cascades vault secrets via FK" do
      vault = insert_vault()
      _s = insert_vault_secret(vault, %{"key" => "WILL_GO"})
      {:ok, _} = Vaults.delete_vault(vault)
      assert Vaults.get_vault(vault.id) == nil
      assert Repo.aggregate(VaultSecret, :count, :id) == 0
    end
  end

  describe "vault secrets" do
    setup do
      {:ok, vault: insert_vault()}
    end

    test "upsert_secret creates if missing", %{vault: vault} do
      {:ok, secret} = Vaults.upsert_secret(vault, %{"key" => "K", "value" => "v1"})
      assert secret.id
      assert {:ok, "v1"} = VaultSecret.decrypt(secret)
    end

    test "upsert_secret updates if present", %{vault: vault} do
      {:ok, _} = Vaults.upsert_secret(vault, %{"key" => "K", "value" => "v1"})
      {:ok, updated} = Vaults.upsert_secret(vault, %{"key" => "K", "value" => "v2"})
      assert {:ok, "v2"} = VaultSecret.decrypt(updated)
      assert length(Vaults.list_secrets(vault)) == 1
    end

    test "key validation rejects lowercase", %{vault: vault} do
      assert {:error, cs} = Vaults.upsert_secret(vault, %{"key" => "lower", "value" => "v"})
      assert "must be UPPER_SNAKE_CASE" in errors_on(cs).key
    end

    test "list_secrets is alphabetical by key", %{vault: vault} do
      insert_vault_secret(vault, %{"key" => "BANANA"})
      insert_vault_secret(vault, %{"key" => "APPLE"})
      keys = Vaults.list_secrets(vault) |> Enum.map(& &1.key)
      assert keys == Enum.sort(keys)
    end

    test "delete_secret removes one row", %{vault: vault} do
      s = insert_vault_secret(vault, %{"key" => "GONE"})
      {:ok, _} = Vaults.delete_secret(s)
      assert Vaults.list_secrets(vault) == []
    end

    test "decrypted_env returns plaintext map", %{vault: vault} do
      insert_vault_secret(vault, %{"key" => "GITHUB_TOKEN", "value" => "ghp_abc"})
      insert_vault_secret(vault, %{"key" => "API_KEY", "value" => "sk_xyz"})

      assert %{"GITHUB_TOKEN" => "ghp_abc", "API_KEY" => "sk_xyz"} =
               Vaults.decrypted_env(vault)
    end

    test "decrypted_env returns empty for vault with no secrets", %{vault: vault} do
      assert Vaults.decrypted_env(vault) == %{}
    end
  end
end
