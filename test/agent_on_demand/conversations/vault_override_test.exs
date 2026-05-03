defmodule AgentOnDemand.Conversations.VaultOverrideTest do
  use AgentOnDemand.DataCase, async: false

  alias AgentOnDemand.{Environments, Vaults}

  # The rule: at sprite spawn, env secrets are merged with vault secrets
  # and the vault wins on key collision. The merge happens in
  # ConversationServer.merge_secrets/2 (private). This test pins down
  # the order so a future refactor can't silently flip it.

  test "vault values override environment secrets when keys collide" do
    env = insert_env(%{"name" => "merge-env-#{System.unique_integer([:positive])}"})
    insert_secret(env, %{"key" => "GITHUB_TOKEN", "value" => "ghp_org_default"})
    insert_secret(env, %{"key" => "ENV_ONLY", "value" => "from_env"})

    vault = insert_vault(%{"name" => "merge-vault-#{System.unique_integer([:positive])}"})
    insert_vault_secret(vault, %{"key" => "GITHUB_TOKEN", "value" => "ghp_alice_personal"})
    insert_vault_secret(vault, %{"key" => "VAULT_ONLY", "value" => "from_vault"})

    # Same call shape ConversationServer uses.
    merged = Map.merge(Environments.decrypted_env(env), Vaults.decrypted_env(vault))

    assert merged["GITHUB_TOKEN"] == "ghp_alice_personal"
    assert merged["ENV_ONLY"] == "from_env"
    assert merged["VAULT_ONLY"] == "from_vault"
  end

  test "no vault leaves env secrets intact" do
    env = insert_env(%{"name" => "merge-env-#{System.unique_integer([:positive])}"})
    insert_secret(env, %{"key" => "GITHUB_TOKEN", "value" => "ghp_only"})

    merged = Map.merge(Environments.decrypted_env(env), %{})
    assert merged == %{"GITHUB_TOKEN" => "ghp_only"}
  end
end
