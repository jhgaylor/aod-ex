# Install

You self-host AoD. There are two supported paths: a single-binary deploy via the bundled CLI (`mix aod.up`), or a Render service via the included `render.yaml`.

## What you need first

- A [Sprites](https://sprites.dev) account and API token (free tier works for development).
- An LLM provider token for whichever runtime(s) you want — Anthropic, OpenAI, Google.
- A reachable URL so spawned agents can call back. For local dev, [cloudflared](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/install-and-setup/tunnel-guide/local/) or [ngrok](https://ngrok.com).

## Deploy via Burrito (`mix aod.up`)

The fastest path. Builds a static Linux binary, pushes it into a Sprite, registers it as a sprite-env service so it survives hibernation, and routes a public URL to it. Single command, your own AoD.

```bash
git clone https://github.com/ravi-hq/agent-on-demand-ex
cd agent-on-demand-ex

mix deps.get
mix aod.up
```

See [Operating → Deploy](operating/deploy.md) for the full walk-through, including the two known Burrito hacks the build relies on and how to retire them.

## Deploy on Render

`render.yaml` provisions:

- One Elixir web service (`mix release`-based) on Render's `starter` plan.
- A 1 GB persistent disk mounted at `/data` for the SQLite database.
- Auto-generated `SECRET_KEY_BASE`.

Set the four `sync: false` env vars in the Render dashboard before the first deploy:

- `ADMIN_TOKEN` — your bearer token. Anyone with this owns the instance.
- `SECRETS_KEY` — 32 bytes url-safe-base64 (no padding), used to encrypt secrets at rest.
- `SPRITES_TOKEN` — your sprites.dev token.
- One of `CLAUDE_CODE_OAUTH_TOKEN` / `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` / `GEMINI_API_KEY` per runtime you'll use.

Generate `SECRETS_KEY`:

```bash
openssl rand 32 | base64 | tr '+/' '-_' | tr -d '='
```

Then commit the repo to a connected GitHub account and trigger a deploy. Migrations run via `preDeployCommand`.

## Local dev

```bash
mix setup     # deps.get + ecto.create + ecto.migrate
mix phx.server
```

Reads a local `.env` automatically. Required vars:

| Var | Notes |
| --- | --- |
| `ADMIN_TOKEN` | Bearer token for the API. |
| `SPRITES_TOKEN` | From sprites.dev. |
| `CLAUDE_CODE_OAUTH_TOKEN` (preferred) or `ANTHROPIC_API_KEY` | Forwarded into each sprite. |
| `AOD_PUBLIC_URL` | Reachable URL for sprite callbacks. Local-dev: cloudflared / ngrok output. |

## Next steps

- [Quickstart](quickstart.md) — five steps to your first conversation.
- [Concepts → Agents](concepts/agents.md) — what the resources mean.
- [SDKs](sdks/python.md) — call the API from Python, TypeScript, Go, or Elixir.
