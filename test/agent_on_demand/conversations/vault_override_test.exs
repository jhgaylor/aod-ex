defmodule AgentOnDemand.Conversations.VaultOverrideTest do
  use AgentOnDemand.DataCase, async: false

  alias AgentOnDemand.{Environments, Substitution, Vaults}

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

  describe "${VAR} substitution against env_vars + secrets + vault" do
    test "vault token wins over env token in MCP headers" do
      env =
        insert_env(%{
          "name" => "subst-env-#{System.unique_integer([:positive])}",
          "env_vars" => %{"PROJECT_ROOT" => "/workspace/repo"}
        })

      insert_secret(env, %{"key" => "GITHUB_TOKEN", "value" => "ghp_org_default"})

      vault = insert_vault(%{"name" => "subst-vault-#{System.unique_integer([:positive])}"})
      insert_vault_secret(vault, %{"key" => "GITHUB_TOKEN", "value" => "ghp_alice"})

      mcp_servers = %{
        "github" => %{
          "type" => "http",
          "headers" => %{"Authorization" => "Bearer ${GITHUB_TOKEN}"}
        },
        "stdio" => %{
          "command" => "node",
          "args" => ["server.js", "--root", "${PROJECT_ROOT}"]
        }
      }

      vars =
        Map.merge(
          %{"PROJECT_ROOT" => "/workspace/repo"},
          Map.merge(Environments.decrypted_env(env), Vaults.decrypted_env(vault))
        )

      assert {:ok, out} = Substitution.apply(mcp_servers, vars)
      assert get_in(out, ["github", "headers", "Authorization"]) == "Bearer ghp_alice"
      assert get_in(out, ["stdio", "args"]) == ["server.js", "--root", "/workspace/repo"]
    end

    test "missing reference surfaces every name at once" do
      mcp_servers = %{
        "a" => %{"headers" => %{"X" => "${MISSING_A}"}},
        "b" => %{"args" => ["${MISSING_B}", "${MISSING_A}"]}
      }

      assert {:error, {:missing_vars, ["MISSING_A", "MISSING_B"]}} =
               Substitution.apply(mcp_servers, %{})
    end

    test "$${VAR} survives untouched so the runtime can expand it itself" do
      mcp_servers = %{"only_runtime" => %{"args" => ["--token", "$${RUNTIME_TOKEN}"]}}

      assert {:ok, %{"only_runtime" => %{"args" => ["--token", "${RUNTIME_TOKEN}"]}}} =
               Substitution.apply(mcp_servers, %{"RUNTIME_TOKEN" => "should-be-ignored"})
    end
  end
end
