---
name: Git Identity Vault Override
description: Design spec for allowing vault secrets to override git author/committer identity in spawned sprites
type: project
---

# Git Identity Vault Override — Design Spec

## Goal

Let operators set `GIT_AUTHOR_NAME` and `GIT_AUTHOR_EMAIL` as vault secrets to override the hardcoded `AoD / aod@local` git identity used by spawned agents.

## Current state

`conversation_server.ex:git_author_env/0` hardcodes all four git identity env vars:

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

`build_sprite_env/4` appends these before secrets, so duplicate keys exist if a user sets them in a vault. Linux `execve` duplicate-key behavior is undefined (typically first wins), making vault override unreliable.

## Design

### Convention

Two reserved vault secret keys:

| Key | Purpose |
|-----|---------|
| `GIT_AUTHOR_NAME` | Full name used for both author and committer |
| `GIT_AUTHOR_EMAIL` | Email used for both author and committer |

If either is absent, the hardcoded default applies for that field.

### Code changes

**`apps/agent_on_demand/lib/agent_on_demand/conversations/conversation_server.ex`**

`git_author_env/1` accepts a secrets subset map:

```elixir
def git_author_env(secrets) do
  name  = secrets["GIT_AUTHOR_NAME"]  || "AoD"
  email = secrets["GIT_AUTHOR_EMAIL"] || "aod@local"
  [
    {"GIT_AUTHOR_NAME",    name},
    {"GIT_AUTHOR_EMAIL",   email},
    {"GIT_COMMITTER_NAME", name},
    {"GIT_COMMITTER_EMAIL", email}
  ]
end
```

`build_sprite_env/4` extracts git keys from secrets and drops them from the remainder (no duplicate env vars):

```elixir
defp build_sprite_env(runtime_module, agent, env, secrets) do
  git_secrets  = Map.take(secrets, ["GIT_AUTHOR_NAME", "GIT_AUTHOR_EMAIL"])
  rest_secrets = Map.drop(secrets, ["GIT_AUTHOR_NAME", "GIT_AUTHOR_EMAIL"])

  (runtime_module.default_env(agent) || []) ++
    aod_callback_env() ++
    otel_propagation_env() ++
    git_author_env(git_secrets) ++
    (if env,
      do: Enum.map(env.env_vars, fn {k, v} -> {to_string(k), to_string(v)} end),
      else: []) ++
    Enum.map(rest_secrets, fn {k, v} -> {k, v} end)
end
```

### Tests

**`apps/agent_on_demand/test/agent_on_demand/conversations/conversation_server_test.exs`**

Update existing call `git_author_env()` → `git_author_env(%{})`.

Add two new cases:

```elixir
test "git_author_env/1 returns defaults when secrets are empty" do
  assert ConversationServer.git_author_env(%{}) == [
    {"GIT_AUTHOR_NAME",    "AoD"},
    {"GIT_AUTHOR_EMAIL",   "aod@local"},
    {"GIT_COMMITTER_NAME", "AoD"},
    {"GIT_COMMITTER_EMAIL", "aod@local"}
  ]
end

test "git_author_env/1 uses vault-supplied name and email for all four vars" do
  secrets = %{"GIT_AUTHOR_NAME" => "Alice", "GIT_AUTHOR_EMAIL" => "alice@example.com"}
  assert ConversationServer.git_author_env(secrets) == [
    {"GIT_AUTHOR_NAME",    "Alice"},
    {"GIT_AUTHOR_EMAIL",   "alice@example.com"},
    {"GIT_COMMITTER_NAME", "Alice"},
    {"GIT_COMMITTER_EMAIL", "alice@example.com"}
  ]
end
```

### Documentation

**`apps/agent_on_demand/priv/help/vaults.md`**

Add a "Git identity" section after "Override semantics":

```markdown
## Git identity

Two vault secrets control the git author and committer identity for every commit an agent makes:

| Key | Description |
|-----|-------------|
| `GIT_AUTHOR_NAME` | Full name (author + committer) |
| `GIT_AUTHOR_EMAIL` | Email (author + committer) |

```bash
aod vault set-secret alice GIT_AUTHOR_NAME  "Alice Smith"
aod vault set-secret alice GIT_AUTHOR_EMAIL "alice@example.com"
```

Or in a manifest:

```yaml
---
apiVersion: aod/v1
kind: Vault
metadata:
  name: alice
spec:
  secrets:
    GIT_AUTHOR_NAME:  Alice Smith
    GIT_AUTHOR_EMAIL: alice@example.com
    GITHUB_TOKEN:     ghp_alice_...
```

When `alice` is picked at conversation start, agents commit as `Alice Smith <alice@example.com>`.
Without these keys the default `AoD <aod@local>` identity is used.
```

## What this does NOT do

- No DB schema change — `GIT_AUTHOR_NAME` / `GIT_AUTHOR_EMAIL` are just vault secrets like any other
- No API surface change
- Author and committer are always kept in sync — separate author/committer identity is not supported

## Success criteria

1. `mix test` passes (including updated + new `git_author_env` tests)
2. A conversation started with a vault containing `GIT_AUTHOR_NAME=Alice` / `GIT_AUTHOR_EMAIL=alice@example.com` sees those values in the sprite process environment (verified via test)
3. A conversation with no vault still gets `AoD / aod@local`
4. `priv/help/vaults.md` documents the two keys
