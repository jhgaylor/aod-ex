# Git Identity Vault Override — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Allow operators to override git author/committer identity by setting `GIT_AUTHOR_NAME` and `GIT_AUTHOR_EMAIL` as vault secrets, replacing the hardcoded `AoD / aod@local` defaults.

**Architecture:** `git_author_env/0` in `ConversationServer` is replaced by `git_author_env/1` that accepts the merged secrets map and reads from it first. `build_sprite_env/4` extracts those two keys from secrets before passing the remainder, eliminating duplicate env vars in the spawned process.

**Tech Stack:** Elixir 1.19.x, ExUnit

---

## File map

| Action | Path |
|--------|------|
| Modify | `apps/agent_on_demand/lib/agent_on_demand/conversations/conversation_server.ex` |
| Modify | `apps/agent_on_demand/test/agent_on_demand/conversations/conversation_server_test.exs` |
| Modify | `apps/agent_on_demand/priv/help/vaults.md` |

---

### Task 1: Replace `git_author_env/0` with `git_author_env/1` (TDD)

**Files:**
- Modify: `apps/agent_on_demand/lib/agent_on_demand/conversations/conversation_server.ex:524-531`
- Modify: `apps/agent_on_demand/lib/agent_on_demand/conversations/conversation_server.ex:511-521`
- Modify: `apps/agent_on_demand/test/agent_on_demand/conversations/conversation_server_test.exs:274-282`

> **Note on running tests:** The repo's `.tool-versions` pins Elixir 1.19.5. If that version isn't installed, run `elixir-version install 1.19.5` first and wait for it to complete. All `mix test` commands below assume you're in `/workspace/agent-on-demand`.

- [ ] **Step 1: Write the failing tests**

Open `apps/agent_on_demand/test/agent_on_demand/conversations/conversation_server_test.exs`.

Replace the existing `describe "git_author_env/0"` block (lines 274–282) with:

```elixir
describe "git_author_env/1" do
  test "returns AoD defaults when secrets map is empty" do
    assert ConversationServer.git_author_env(%{}) == [
      {"GIT_AUTHOR_NAME", "AoD"},
      {"GIT_AUTHOR_EMAIL", "aod@local"},
      {"GIT_COMMITTER_NAME", "AoD"},
      {"GIT_COMMITTER_EMAIL", "aod@local"}
    ]
  end

  test "uses vault-supplied name and email for all four git vars" do
    secrets = %{"GIT_AUTHOR_NAME" => "Alice", "GIT_AUTHOR_EMAIL" => "alice@example.com"}

    assert ConversationServer.git_author_env(secrets) == [
      {"GIT_AUTHOR_NAME", "Alice"},
      {"GIT_AUTHOR_EMAIL", "alice@example.com"},
      {"GIT_COMMITTER_NAME", "Alice"},
      {"GIT_COMMITTER_EMAIL", "alice@example.com"}
    ]
  end

  test "falls back to default for missing name" do
    assert ConversationServer.git_author_env(%{"GIT_AUTHOR_EMAIL" => "alice@example.com"}) == [
      {"GIT_AUTHOR_NAME", "AoD"},
      {"GIT_AUTHOR_EMAIL", "alice@example.com"},
      {"GIT_COMMITTER_NAME", "AoD"},
      {"GIT_COMMITTER_EMAIL", "alice@example.com"}
    ]
  end

  test "falls back to default for missing email" do
    assert ConversationServer.git_author_env(%{"GIT_AUTHOR_NAME" => "Alice"}) == [
      {"GIT_AUTHOR_NAME", "Alice"},
      {"GIT_AUTHOR_EMAIL", "aod@local"},
      {"GIT_COMMITTER_NAME", "Alice"},
      {"GIT_COMMITTER_EMAIL", "aod@local"}
    ]
  end
end
```

- [ ] **Step 2: Run tests — expect failures**

```bash
cd /workspace/agent-on-demand
mix test apps/agent_on_demand/test/agent_on_demand/conversations/conversation_server_test.exs --grep "git_author_env" 2>&1
```

Expected output: 4 failures — `git_author_env/1` is undefined (the existing 0-arity function is still in place).

- [ ] **Step 3: Replace `git_author_env/0` with `git_author_env/1` in `conversation_server.ex`**

Open `apps/agent_on_demand/lib/agent_on_demand/conversations/conversation_server.ex`.

**Replace** lines 524–531 (the `git_author_env/0` definition):

```elixir
  def git_author_env do
    [
      {"GIT_AUTHOR_NAME", "AoD"},
      {"GIT_AUTHOR_EMAIL", "aod@local"},
      {"GIT_COMMITTER_NAME", "AoD"},
      {"GIT_COMMITTER_EMAIL", "aod@local"}
    ]
  end
```

**With:**

```elixir
  @doc false
  def git_author_env(secrets) do
    name  = secrets["GIT_AUTHOR_NAME"]  || "AoD"
    email = secrets["GIT_AUTHOR_EMAIL"] || "aod@local"
    [
      {"GIT_AUTHOR_NAME",     name},
      {"GIT_AUTHOR_EMAIL",    email},
      {"GIT_COMMITTER_NAME",  name},
      {"GIT_COMMITTER_EMAIL", email}
    ]
  end
```

- [ ] **Step 4: Update `build_sprite_env/4` to pass secrets to `git_author_env/1`**

In the same file, **replace** lines 511–521 (`build_sprite_env/4`):

```elixir
  defp build_sprite_env(runtime_module, agent, env, secrets) do
    (runtime_module.default_env(agent) || []) ++
      aod_callback_env() ++
      otel_propagation_env() ++
      git_author_env() ++
      if(env,
        do: Enum.map(env.env_vars, fn {k, v} -> {to_string(k), to_string(v)} end),
        else: []
      ) ++
      Enum.map(secrets, fn {k, v} -> {k, v} end)
  end
```

**With:**

```elixir
  defp build_sprite_env(runtime_module, agent, env, secrets) do
    git_secrets  = Map.take(secrets, ["GIT_AUTHOR_NAME", "GIT_AUTHOR_EMAIL"])
    rest_secrets = Map.drop(secrets, ["GIT_AUTHOR_NAME", "GIT_AUTHOR_EMAIL"])

    (runtime_module.default_env(agent) || []) ++
      aod_callback_env() ++
      otel_propagation_env() ++
      git_author_env(git_secrets) ++
      if(env,
        do: Enum.map(env.env_vars, fn {k, v} -> {to_string(k), to_string(v)} end),
        else: []
      ) ++
      Enum.map(rest_secrets, fn {k, v} -> {k, v} end)
  end
```

- [ ] **Step 5: Run tests — expect all passing**

```bash
cd /workspace/agent-on-demand
mix test apps/agent_on_demand/test/agent_on_demand/conversations/conversation_server_test.exs 2>&1
```

Expected: all tests in the file pass, including the four new `git_author_env/1` tests.

- [ ] **Step 6: Run full test suite**

```bash
cd /workspace/agent-on-demand
mix test 2>&1 | tail -20
```

Expected: no new failures.

- [ ] **Step 7: Commit**

```bash
cd /workspace/agent-on-demand
git add \
  apps/agent_on_demand/lib/agent_on_demand/conversations/conversation_server.ex \
  apps/agent_on_demand/test/agent_on_demand/conversations/conversation_server_test.exs
git commit -m "feat: allow vault secrets to override git author/committer identity"
```

---

### Task 2: Document git identity in `vaults.md`

**Files:**
- Modify: `apps/agent_on_demand/priv/help/vaults.md`

- [ ] **Step 1: Add "Git identity" section after "Override semantics"**

Open `apps/agent_on_demand/priv/help/vaults.md`. After the "Override semantics" section (which ends around the "Repository clones..." sentence) and before the "Manifest" section, insert:

```markdown
## Git identity

Two vault secrets control the git author and committer identity for every commit an agent makes inside the sprite:

| Key | Description |
|-----|-------------|
| `GIT_AUTHOR_NAME` | Full name — used for both author and committer |
| `GIT_AUTHOR_EMAIL` | Email — used for both author and committer |

```bash
aod vault set-secret alice GIT_AUTHOR_NAME  "Alice Smith"
aod vault set-secret alice GIT_AUTHOR_EMAIL "alice@example.com"
```

Without these keys the default `AoD <aod@local>` identity is used. Override applies to all git operations the agent performs inside the sprite (commits, tags, etc.).

```

- [ ] **Step 2: Also add a manifest example to the existing "Manifest" section**

Find the manifest YAML block in `vaults.md` (the one with `GITHUB_TOKEN` and `NPM_TOKEN`). Extend it to show git identity keys alongside real credentials:

```yaml
---
apiVersion: aod/v1
kind: Vault
metadata:
  name: alice
spec:
  description: Alice's credentials
  secrets:
    GIT_AUTHOR_NAME:  Alice Smith
    GIT_AUTHOR_EMAIL: alice@example.com
    GITHUB_TOKEN:     ghp_alice_...
    NPM_TOKEN:        npm_alice_...
```

- [ ] **Step 3: Commit**

```bash
cd /workspace/agent-on-demand
git add apps/agent_on_demand/priv/help/vaults.md
git commit -m "docs: document git identity vault secrets in vaults.md"
```

---

### Task 3: Open the PR

- [ ] **Step 1: Push the branch**

```bash
cd /workspace/agent-on-demand
git push
```

- [ ] **Step 2: Create the PR**

```bash
gh pr create \
  --title "feat: allow vault secrets to override git author/committer identity" \
  --body "$(cat <<'EOF'
## Summary

- Replaces hardcoded `AoD / aod@local` git identity with vault-configurable values
- `GIT_AUTHOR_NAME` and `GIT_AUTHOR_EMAIL` vault secrets are consumed by `git_author_env/1` and used for both author and committer
- Falls back to `AoD / aod@local` when the secrets are absent
- Eliminates the previous duplicate-env-var pattern (git keys are now extracted from secrets before appending the remainder to the process env)
- Documents the two keys in `priv/help/vaults.md`

No DB schema changes — these are plain vault secrets like `GITHUB_TOKEN`.

## Test plan

- [ ] `mix test apps/agent_on_demand/test/agent_on_demand/conversations/conversation_server_test.exs` — 4 new `git_author_env/1` tests pass
- [ ] `mix test` — full suite green
- [ ] Read `priv/help/vaults.md` Git identity section — examples are accurate

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

---

## Self-review

**Spec coverage:**
- ✅ `git_author_env/1` with secrets map — Task 1 steps 3–4
- ✅ `build_sprite_env/4` passes git secrets, drops from remainder — Task 1 step 4
- ✅ Default fallback (empty map) — Task 1 step 1 test case 1
- ✅ Full override (both keys) — Task 1 step 1 test case 2
- ✅ Partial fallback (name only, email only) — Task 1 step 1 test cases 3–4
- ✅ `vaults.md` Git identity section — Task 2
- ✅ Manifest example updated — Task 2 step 2

**Placeholder scan:** No TBDs, no vague steps. Every code block is complete.

**Type consistency:** `git_author_env/1` takes `map()` throughout. `build_sprite_env` uses `Map.take/2` and `Map.drop/2` which return maps. `Enum.map(rest_secrets, ...)` handles the map correctly.
