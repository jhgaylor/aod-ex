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

# Define an agent with skills. Each entry is either inline (full SKILL.md
# in `content`) or github (resolved via the skills.sh CLI on the sprite).
curl -X POST $BASE/api/agents -H "Authorization: Bearer $TOKEN" \
  -H 'content-type: application/json' \
  -d '{
    "name":"researcher",
    "model":"anthropic/claude-sonnet-4-6",
    "runtime":"claude",
    "skills": [
      {"source":"anthropics/skills","name":"frontend-design"},
      {"name":"house-style","content":"---\nname: house-style\n---\nUse our voice."}
    ]
  }'

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
- **Agent** — name, system prompt, model, runtime, optional environment, optional MCP servers, optional skills (each entry inline `{name, content}` or github `{source, name?}` — see [Skills](#skills) below).
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

## Skills

An agent's `skills` is a list of two shapes:

- **inline** — `{"name": "...", "content": "<full SKILL.md body>"}`. Written to `<runtime-skills-root>/<name>/SKILL.md` on the sprite.
- **github** — `{"source": "owner/repo", "name": "<optional skill within the repo>"}`. Installed on the sprite via the [skills.sh](https://skills.sh) CLI (`npx -y skills@latest add <source> --global --agent <runtime-agent> --yes [--skill <name>]`). Omit `name` to install every skill in the repo.

The bundled `aod` skill is always prepended automatically — it's how spawned agents call back to your AoD instance.

YAML manifest example for `aod apply`:

```yaml
apiVersion: aod/v1
kind: Agent
metadata:
  name: researcher
spec:
  model: anthropic/claude-sonnet-4-6
  runtime: claude
  skills:
    - source: anthropics/skills
      name: frontend-design
    - name: house-style
      content: |
        ---
        name: house-style
        ---
        Use our voice.
```

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

## Production deploy (Sprites — `aod up`)

One command deploys into a Sprite (the same primitive that runs each conversation). Two equivalent entry points:

```bash
SPRITES_TOKEN=... mix aod.up           # from a project checkout
SPRITES_TOKEN=... ./aod up             # from a downloaded release binary, no Erlang needed
# → URL: https://aod-<id>-<region>.sprites.app
# → ADMIN_TOKEN: <copy from output, log in with this>
```

Both paths share `AodCli.Up.dispatch/1` so they behave identically. The released binary embeds `aod up` / `aod down` as subcommands so you don't need a checkout to deploy.

By default the linux binary is fetched from the GitHub release matching the build's version (`v0.1.0`) and cached at `~/.cache/aod/releases/<tag>/`. Override with `--release vX.Y.Z`. If `burrito_out/aod_linux` exists locally (e.g. you ran `MIX_ENV=prod mix release` for an in-flight change), that wins.

The Sprite-side service survives hibernation and auto-starts on incoming requests. Tear down with `aod down <sprite-name>` (or `mix aod.down <sprite-name>`).

### Upgrade in place

Re-run with the same `--name` to swap the binary on an existing deployment without losing state:

```bash
SPRITES_TOKEN=... aod up --name <existing-name>                    # latest local-or-release
SPRITES_TOKEN=... aod up --name <existing-name> --release v0.2.0   # specific release
```

The task detects the existing sprite, recovers `ADMIN_TOKEN` / `SECRETS_KEY` / `SECRET_KEY_BASE` from the `start.sh` it wrote on first deploy, pushes the new binary on top of the old one, and recreates the `sprite-env` service. The SQLite DB at `/opt/aod/data/aod.db` and the encryption key are preserved, so existing agents/environments/vaults/conversations survive.

### Cutting a release

Tag-push to `v*.*.*` triggers `.github/workflows/release.yml`, which builds `aod-linux-x86_64` and `aod-macos-aarch64` (Burrito + Zig 0.15.2) and attaches them to a GitHub release:

```bash
# Bump version: in mix.exs
git commit -am "Release vX.Y.Z"
git tag vX.Y.Z
git push --tags
# → CI builds + uploads release assets
```

The macOS binary is the same dual-mode build — operators can `chmod +x` it and use it as the CLI directly without Erlang installed.

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

A `ConversationServer` GenServer owns each running conversation. On start it provisions a sprite, mounts the agent's skills (always-prepended `aod` callback skill + any inline/github entries — github entries shell out to the [skills.sh](https://skills.sh) CLI), writes any runtime-specific config (e.g. claude's `~/.claude.json` for MCP), runs the env's `setup_script`, then spawns the runtime CLI with stdin'd prompt. stdout/stderr from the sprite are persisted to `log_events` (integer PK for SSE replay) and broadcast on `Phoenix.PubSub` topic `"conv:<id>"`. The SSE endpoint subscribes, replays missed events from `Last-Event-ID`, then live-tails. Multi-turn `--resume` uses claude's own `session_id` extracted from its stream-json `init` message.

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
  sprite_skills.ex     mount agent skills into a sprite (inline + skills.sh)
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
