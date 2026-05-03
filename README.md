# Agent on Demand (Elixir)

[![CI](https://github.com/ravi-hq/agent-on-demand-ex/actions/workflows/ci.yml/badge.svg)](https://github.com/ravi-hq/agent-on-demand-ex/actions/workflows/ci.yml)

A REST API for spawning AI coding agents (claude, codex, gemini, opencode) inside Sprites and streaming their output. Single-tenant, SQLite-backed, written in Elixir.

The original Python/Django implementation lives at [ravi-hq/agent-on-demand](https://github.com/ravi-hq/agent-on-demand). This is a ground-up rewrite.

## What you can do

```bash
TOKEN="$ADMIN_TOKEN"
BASE=http://localhost:4000

# Define an environment: packages, env vars, networking, repos, setup script
curl -X POST $BASE/api/environments -H "Authorization: Bearer $TOKEN" \
  -H 'content-type: application/json' \
  -d '{
    "name": "ravi-hq",
    "packages": {"apt": ["jq", "ripgrep"]},
    "env_vars": {"PROJECT_ROOT": "/workspace/agent-on-demand"},
    "networking_type": "limited",
    "networking_config": {"allowed_hosts": ["github.com", "api.anthropic.com", "registry.npmjs.org"]},
    "repositories": [
      {
        "url": "https://github.com/ravi-hq/agent-on-demand",
        "mount_path": "/workspace/agent-on-demand",
        "secret_key": "GITHUB_TOKEN"
      }
    ],
    "setup_script": "cd /workspace/agent-on-demand && uv sync"
  }'

# Add the secret referenced by repositories[].secret_key
curl -X POST $BASE/api/environments/<env_id>/secrets -H "Authorization: Bearer $TOKEN" \
  -H 'content-type: application/json' \
  -d '{"key":"GITHUB_TOKEN","value":"ghp_..."}'

# Define a vault — a free-floating bag of env-var overrides applied at conversation creation.
# Layered on top of the environment's secrets; vault values win on key collision.
curl -X POST $BASE/api/vaults -H "Authorization: Bearer $TOKEN" \
  -H 'content-type: application/json' \
  -d '{"name":"alice","description":"Alice'"'"'s personal credentials"}'

curl -X POST $BASE/api/vaults/<vault_id>/secrets -H "Authorization: Bearer $TOKEN" \
  -H 'content-type: application/json' \
  -d '{"key":"GITHUB_TOKEN","value":"ghp_alice_..."}'

# Define an agent
curl -X POST $BASE/api/agents -H "Authorization: Bearer $TOKEN" \
  -H 'content-type: application/json' \
  -d '{"name":"hello","model":"anthropic/claude-sonnet-4-6","runtime":"claude","environment_id":"<env_id>"}'

# Start a conversation: provisions a sprite, runs setup_script, mounts skills,
# fires turn 1, returns immediately. Optional vault_id overrides env secrets.
curl -X POST $BASE/api/conversations -H "Authorization: Bearer $TOKEN" \
  -H 'content-type: application/json' \
  -d '{"agent_id":"<agent_id>","vault_id":"<vault_id>","prompt":"Hello there."}'

# Stream output (SSE); reconnect with Last-Event-ID to resume.
curl -N $BASE/api/conversations/<conv_id>/stream -H "Authorization: Bearer $TOKEN"

# Send another prompt — uses claude --resume to continue the conversation.
curl -X POST $BASE/api/conversations/<conv_id>/prompts -H "Authorization: Bearer $TOKEN" \
  -d '{"prompt":"What did I just ask?"}'

# Tear down (destroys sprite).
curl -X POST $BASE/api/conversations/<conv_id>/terminate -H "Authorization: Bearer $TOKEN"
```

The full API is documented as an OpenAPI 3 spec, generated from the controller `operation` decls:

- `GET /api/openapi.json` — the spec itself, no auth.
- `GET /api/docs` — Swagger UI, no auth (clicking "Authorize" lets you try authenticated calls).

## CLI

There's a single-binary CLI built from this repo:

```bash
mix escript.build      # produces ./aod
export AOD_BASE_URL=http://localhost:4000
export AOD_TOKEN=...
./aod agent list
./aod env list
./aod vault list
./aod vault create alice --description "Alice's creds"
./aod vault set-secret alice GITHUB_TOKEN ghp_alice_...
./aod conv list
./aod run hello -p "Say hi."                       # start + stream + wait
./aod run hello -p "Say hi." --vault alice         # ...with vault overrides
./aod conv prompt <conv-id> -p "..."               # follow-up turn
./aod conv interrupt <conv-id>         # stop the running turn, keep sandbox
./aod conv terminate <conv-id>         # destroy the sprite
./aod conv delete <conv-id>            # destroy sprite + delete the row
```

## Resource model

Three resources, with a clear split between "sandbox lifespan" and "chat history":

- **Environment** — packages, env vars, setup script, networking config; owns first-class encrypted **Secrets** (the env's baseline).
- **Vault** — a free-floating bag of encrypted env-var overrides. Selected on a per-conversation basis (yours, a teammate's, a virtual identity's). Layered over the environment's secrets at sprite spawn; vault values win on key collision. Use it to override `GITHUB_TOKEN` per conversation, etc.
- **Agent** — name, system prompt, model, runtime, optional environment, optional MCP servers, optional skills.
- **Sandbox** — one running sprite. Status lifecycle: `pending → starting → ready → terminated|failed`.
- **Conversation** — one chat with one agent inside one sandbox, optionally using one vault. Has many **Turns**; each turn is one `prompt → exit_code` cycle. The `runtime_session_id` is captured from claude and persisted so resumption survives process restarts.
- **LogEvent** — the firehose. Two kinds: `output` (stdout/stderr lines from the runtime CLI) and `stage` (lifecycle markers — provision, setup, turn, terminate). Integer PK lets clients use `Last-Event-ID` for SSE replay.

## Local dev

```bash
mix setup        # mix deps.get + ecto.create + ecto.migrate
mix phx.server   # serves on :4000
```

Reads a local `.env` automatically (see `.env.example`):

| Var | Required | Notes |
| --- | --- | --- |
| `ADMIN_TOKEN` | yes | Bearer token for the API. |
| `SPRITES_TOKEN` | yes | From sprites.dev. |
| `CLAUDE_CODE_OAUTH_TOKEN` | preferred for `claude` runtime | Forwarded into each sprite. Takes precedence over `ANTHROPIC_API_KEY` and bills against a Claude.ai Pro/Team subscription. |
| `ANTHROPIC_API_KEY` | fallback for `claude` runtime | Forwarded into each sprite (metered API billing). |
| `OPENAI_API_KEY` | for future `codex` runtime | |
| `GEMINI_API_KEY` | for future `gemini` runtime | |
| `SECRETS_KEY` | prod only | 32 bytes, base64 url-safe (no padding). Dev derives from a fixed seed. |
| `AOD_PUBLIC_URL` | optional | If set, exposed inside sprites via the bundled `aod` skill so spawned agents can fan out to more conversations. Must be reachable from inside the sprite — see [Tunneling](#tunneling-for-the-aod-skill) below. |

## Tunneling (for the `aod` skill)

The bundled `aod` skill lets a spawned agent call back to your AoD instance to start more conversations. For that to work, `AOD_PUBLIC_URL` has to be reachable from inside a sprite — `localhost` won't do.

The cleanest local-dev option is [cloudflared](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/install-and-setup/tunnel-guide/local/):

```bash
brew install cloudflared
cloudflared tunnel --url http://localhost:4000
# → outputs: https://random-words.trycloudflare.com
```

Set that URL as `AOD_PUBLIC_URL` in `.env` and restart the server. Any sprite provisioned afterward will get `AOD_BASE_URL` + `AOD_TOKEN` exported and the `aod` skill will work.

[ngrok](https://ngrok.com) and [tailscale funnel](https://tailscale.com/kb/1223/funnel) work too. ngrok requires a free account; tailscale funnel needs a tailnet.

## Production deploy (Sprites — `mix aod.up`)

One-command deploy into a Sprite (the same primitive that runs each conversation):

```bash
SPRITES_TOKEN=... MIX_ENV=prod mix release
SPRITES_TOKEN=... mix aod.up
# → URL: https://aod-<id>-<region>.sprites.app
# → ADMIN_TOKEN: <copy from output, log in with this>
```

The Sprite-side service survives hibernation and auto-starts on incoming requests. Tear down with `mix aod.up --destroy <sprite-name>`.

Requires Zig 0.15.2 on `PATH` for Burrito's cross-build, and a few Burrito workarounds documented in [docs/deploy.md](docs/deploy.md) — they're paid-down candidates, not load-bearing forever.

## Production deploy (Render)

`render.yaml` provisions:

- One Elixir web service (`mix release`-based) on Render's free `starter` plan.
- A 1 GB persistent disk mounted at `/data` for SQLite.
- Auto-generated `SECRET_KEY_BASE`.
- `ADMIN_TOKEN`, `SECRETS_KEY`, `SPRITES_TOKEN`, `ANTHROPIC_API_KEY` left as `sync: false` — set them in the Render dashboard.

```bash
# After connecting the repo to Render, on first deploy:
# 1. Set the four sync:false env vars in the dashboard
# 2. SECRETS_KEY must be 32 bytes url-safe-base64 (no padding):
openssl rand 32 | base64 | tr '+/' '-_' | tr -d '='
# 3. Trigger deploy. Migrations run via the preDeployCommand.
```

`PHX_HOST` and `AOD_PUBLIC_URL` default to `agent-on-demand.onrender.com` — change them in `render.yaml` if you use a custom domain.

## Architecture (one paragraph)

A `ConversationServer` GenServer owns each running conversation. On start it provisions a sprite, mounts bundled skills (`priv/sprite_skills/aod/`), writes any runtime-specific config (e.g. claude's `~/.claude.json` for MCP), runs the env's `setup_script`, then spawns the runtime CLI with stdin'd prompt. stdout/stderr from the sprite are persisted to `log_events` (integer PK for SSE replay) and broadcast on `Phoenix.PubSub` topic `"conv:<id>"`. The SSE endpoint subscribes, replays missed events from `Last-Event-ID`, then live-tails. Multi-turn `--resume` uses claude's own `session_id` extracted from its stream-json `init` message.

## Layout

```
config/                runtime config + .env loader
lib/agent_on_demand/
  agents/              Agent schema + context
  conversations/       Sandbox, Conversation, Turn, LogEvent + ConversationServer GenServer
  environments/        Environment, Secret + context (with AES-GCM at rest)
  vaults/              Vault, VaultSecret + context (per-conversation env-var overrides)
  runtimes/            Runtimes behaviour + Claude impl
  application.ex       supervision tree
  crypto.ex            AES-256-GCM
  sprite_skills.ex     mount bundled skills into a sprite
lib/agent_on_demand_web/
  controllers/         REST + SSE
  plugs/admin_auth.ex  bearer-token auth
  router.ex
  api_spec.ex          OpenAPI 3 spec (served at /api/openapi.json, /api/docs)
  schemas.ex           shared OpenAPI schemas referenced by controller decls
priv/sprite_skills/
  aod/SKILL.md         the spawn-more-conversations skill
priv/repo/migrations/
```
