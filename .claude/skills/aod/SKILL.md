---
name: aod
description: Use when working with Agent on Demand (AoD) — deploying an AoD instance on Sprites or Render, configuring environments/agents/vaults, using the API/CLI/UI, and spawning parallel AI coding agents. Covers deployment, configuration, API patterns, SSE streaming, multi-turn conversations, vaults, and skill management. Reads `AOD_BASE_URL` and `AOD_TOKEN` from the environment.
---

# Agent on Demand (AoD)

AoD is a single-tenant REST API (+ LiveView UI + CLI) that provisions isolated
Sprites, runs AI coding agents inside them, and streams output over SSE. Each
conversation gets its own fresh sandbox.

Source: [jhgaylor/aod-ex](https://github.com/jhgaylor/aod-ex)

## Key Concepts

| Concept | What it is |
|---------|------------|
| **Environment** | Sandbox template: packages, env vars, setup script, repos, networking |
| **Agent** | Name, model, runtime (`claude`/`codex`/`gemini`/`opencode`), skills list |
| **Vault** | Free-floating env-var overrides layered per-conversation |
| **Conversation** | One chat with one agent in one sandbox |
| **Sandbox** | One running Sprite (ephemeral) |
| **Skill** | Markdown instruction file prepended to every agent's context |

## Deploying AoD

### Option A — Into a Sprite (recommended)

```bash
mix aod.up
```

Compiles and deploys AoD into a Sprite via sprites.dev. Self-contained —
SQLite on the Sprite's persistent filesystem, no external database needed.

### Option B — Render

The repo ships a `render.yaml`. Deploy as a web service with a persistent
disk for SQLite — works out of the box with the Render dashboard.

### Critical: `AOD_PUBLIC_URL`

`AOD_PUBLIC_URL` must be reachable from **inside spawned Sprites** —
`localhost` won't work. For local dev, tunnel first:

```bash
cloudflared tunnel --url http://localhost:4000
# or: ngrok http 4000
# or: tailscale funnel 4000
```

Set `AOD_PUBLIC_URL` to the tunnel URL before starting AoD.

## Three Surfaces

All three expose identical capabilities:

- **API** — JSON over HTTP under `/api/*`
- **CLI** — `./aod` binary (`mix escript.build`)
- **UI** — Phoenix LiveView at `/`

## Authentication

All API calls require:

```
Authorization: Bearer $AOD_TOKEN
```

`AOD_TOKEN` is the single-tenant admin token configured at deploy time.
All spawned agents share it — don't leak it outside your Sprites.

## API Quick Reference

Base: `$AOD_BASE_URL/api`

> **Common mistake**: `/conversations` (without `/api`) redirects to the
> LiveView UI (302 → /login for non-browsers). Always use `/api/conversations`.

### List resources

```bash
# Agents
curl -s "$AOD_BASE_URL/api/agents" -H "Authorization: Bearer $AOD_TOKEN" | jq .

# Environments
curl -s "$AOD_BASE_URL/api/environments" -H "Authorization: Bearer $AOD_TOKEN" | jq .

# Vaults
curl -s "$AOD_BASE_URL/api/vaults" -H "Authorization: Bearer $AOD_TOKEN" | jq .

# Conversations
curl -s "$AOD_BASE_URL/api/conversations" -H "Authorization: Bearer $AOD_TOKEN" | jq .
```

### Spawn a conversation

```bash
AGENT_ID=$(curl -s "$AOD_BASE_URL/api/agents" \
  -H "Authorization: Bearer $AOD_TOKEN" \
  | jq -r '.data[] | select(.name == "my-agent") | .id')

CONV=$(curl -s -X POST "$AOD_BASE_URL/api/conversations" \
  -H "Authorization: Bearer $AOD_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg a "$AGENT_ID" --arg p "Your prompt here" '{agent_id:$a, prompt:$p}')" \
  | jq -r .data.id)

echo "Conversation: $CONV"
```

### Check status

```bash
curl -s "$AOD_BASE_URL/api/conversations/$CONV" \
  -H "Authorization: Bearer $AOD_TOKEN" \
  | jq -r .data.status
```

Statuses: `pending` → `running` → `completed` / `failed` / `terminated`

### Stream output (SSE)

```bash
curl -sN "$AOD_BASE_URL/api/conversations/$CONV/stream?streams=stdout&wait=false" \
  -H "Authorization: Bearer $AOD_TOKEN"
```

#### SSE wire format

```
id: 2694
event: output
data: {"data":"{\"type\":\"result\",...}","stream":"stdout","stage":"turn",...}
```

Two layers of JSON. The outer object's `.data` field is a JSON-encoded string
that needs `fromjson` to peel. The `awk` strips the `data: ` prefix:

```bash
curl -sN --max-time 5 \
  "$AOD_BASE_URL/api/conversations/$CONV/stream?streams=stdout&wait=false" \
  -H "Authorization: Bearer $AOD_TOKEN" \
| awk '/^data: /{sub(/^data: /,""); print}' \
| jq -r '.data | fromjson? | select(.type=="result") | .result' \
| tail -n1
```

#### Per-runtime: where the final text lives

Pull the runtime once, then pick the right filter:

```bash
RT=$(curl -s "$AOD_BASE_URL/api/conversations/$CONV" \
  -H "Authorization: Bearer $AOD_TOKEN" | jq -r .data.runtime)
```

| runtime  | filter (after `.data \| fromjson?`)                                    | text path                        |
|----------|------------------------------------------------------------------------|----------------------------------|
| claude   | `select(.type=="result")`                                              | `.result`                        |
| codex    | `select(.type=="item.completed" and .item.type=="agent_message")`      | `.item.text`                     |
| gemini   | `select(.type=="message" and .role=="assistant")`                      | `.content` *(use the last one)*  |
| opencode | `select(.type=="text")`                                                | `.part.text` *(concatenate all)* |

#### The `wait=false` flag

Always pass `wait=false` when reading a completed conversation — the stream
closes the moment the replay drains (milliseconds) instead of holding open
for 60s. Drop it only when you actually want to live-tail.

### Fan out N agents in parallel

```bash
AGENT_ID=...
prompts=("First task" "Second task" "Third task")

# 1. Spawn all in parallel
ids=$(printf '%s\n' "${prompts[@]}" | xargs -n1 -P8 -I{} sh -c '
  curl -s -X POST "$1/api/conversations" \
    -H "Authorization: Bearer $2" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg a "$3" --arg p "$4" "{agent_id:\$a, prompt:\$p}")" \
  | jq -r .data.id
' _ "$AOD_BASE_URL" "$AOD_TOKEN" "$AGENT_ID" {})

# 2. Wait for all in parallel
echo "$ids" | xargs -n1 -P10 -I{} sh -c '
  while :; do
    s=$(curl -s "$1/api/conversations/$3" -H "Authorization: Bearer $2" | jq -r .data.status)
    case "$s" in running|pending) sleep 2 ;; *) break ;; esac
  done
' _ "$AOD_BASE_URL" "$AOD_TOKEN" {}

# 3. Gather results (claude runtime)
while IFS= read -r conv; do
  echo "=== $conv ==="
  curl -sN --max-time 5 \
    "$AOD_BASE_URL/api/conversations/$conv/stream?streams=stdout&wait=false" \
    -H "Authorization: Bearer $AOD_TOKEN" \
  | awk '/^data: /{sub(/^data: /,""); print}' \
  | jq -r '.data | fromjson? | select(.type=="result") | .result' \
  | tail -n1
done <<<"$ids"
```

### Multi-turn (send a follow-up)

```bash
curl -s -X POST "$AOD_BASE_URL/api/conversations/$CONV/prompts" \
  -H "Authorization: Bearer $AOD_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"prompt":"Now compare that to the worker service."}'
```

Then poll status and read the stream the same way. The runtime session
resumes — the agent remembers turn 1.

### Spawn with a vault

```bash
VAULT_ID=$(curl -s "$AOD_BASE_URL/api/vaults" \
  -H "Authorization: Bearer $AOD_TOKEN" \
  | jq -r '.data[] | select(.name == "my-vault") | .id')

curl -s -X POST "$AOD_BASE_URL/api/conversations" \
  -H "Authorization: Bearer $AOD_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg a "$AGENT_ID" --arg v "$VAULT_ID" --arg p "$PROMPT" \
        '{agent_id:$a, vault_id:$v, prompt:$p}')"
```

Vault values override the environment's baseline on key collision. Useful
when you need a spawned conversation to run with different credentials
(e.g. commit to GitHub as a specific user).

### Terminate

```bash
curl -s -X POST "$AOD_BASE_URL/api/conversations/$CONV/terminate" \
  -H "Authorization: Bearer $AOD_TOKEN"
```

## Skills Management

Skills are markdown instruction files prepended to every agent's context.
The bundled `aod` skill is automatically added to every agent — it mirrors
the usage patterns in this file so spawned agents know how to fan out more
conversations.

Additional skills are installed via the [skills.sh](https://skills.sh) CLI:

```bash
npx -y skills@latest add <source> --global --agent <runtime-agent> --yes
```

To install the `aod` skill from this repo directly into an agent:

```bash
npx -y skills@latest add github:jhgaylor/aod-ex/.claude/skills/aod --global --yes
```

> **Staying in sync**: The bundled `aod` skill that AoD prepends to every
> agent is intended to mirror the API usage sections of this file. If you
> update the API patterns here, update the bundled skill in the Elixir app
> accordingly so spawned agents stay current.

## Important

- **`AOD_PUBLIC_URL` must be externally reachable** — not `localhost`. Use a tunnel for local dev.
- **Always `wait=false` for gather** — otherwise you burn N × `--max-time` seconds for no reason.
- **Parallelize with `xargs -P`** — provisioning takes ~5–15s each; do not do these sequentially.
- **Don't recurse forever** — spawned agents have the bundled aod skill and can spawn more. Cap depth.
- **Costs accumulate** — every conversation provisions a real sandbox.
- **API path is `/api/...`** — bare paths redirect (302) to the LiveView UI.
- **All Sprites prefixed `aod-`** — for discovery via the Sprites API.
