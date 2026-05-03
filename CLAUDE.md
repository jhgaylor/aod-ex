# Agent on Demand (Elixir) — project conventions

This is the in-progress Elixir rewrite of [ravi-hq/agent-on-demand](https://github.com/ravi-hq/agent-on-demand). Single-tenant. SQLite. Sprites via the local `../sprites-ex` fork.

## The three surfaces

The product has three first-class surfaces, not one. Every user-facing capability has to land on all of them:

1. **API** — JSON over HTTP under `/api/*`, bearer-token auth (`ADMIN_TOKEN`). The source of truth; the UI and CLI both go through it.
2. **UI** — Phoenix LiveView at `/`, session-cookie auth (login page takes the same `ADMIN_TOKEN`).
3. **CLI** — `mix escript.build` → `./aod`, reads `AOD_BASE_URL` + `AOD_TOKEN` from env, talks to the API.

When you add a feature, the default is **all three**. Files you almost always touch in one change:

- `lib/agent_on_demand_web/router.ex` — new route under the right scope.
- `lib/agent_on_demand_web/controllers/<resource>_controller.ex` — JSON action.
- `lib/agent_on_demand_web/live/<resource>_live/...ex` — LiveView event handler + button/form/etc.
- `lib/aod_cli/<resource>.ex` — subcommand dispatch.
- `lib/aod_cli.ex` — `@moduledoc` usage block.
- `README.md` — curl example for the new endpoint, CLI line for the new subcommand.

If a context function (`AgentOnDemand.Conversations.*`, etc.) needs to be added or changed, do that first; all three surfaces should call it.

### When NOT to do all three

A few legitimate carve-outs:

- **Pure backend internals** — supervisor structure, schema fields nobody types in by hand, internal refactors.
- **API-only debug endpoints** — `/health`, anything an operator hits with curl that has no business in a UI.
- **CLI-only convenience commands** that compose existing API calls (e.g. a future `aod conv watch --regex` that polls and greps). The user surface is just a different layout of the same primitives.
- **UI-only affordances** — keyboard shortcuts, drag-to-reorder, table sort. They don't change what the system can do, just how it's seen.

If you're cutting a surface, mention it in the PR/commit message — "API + CLI only, UI deferred because X" — so it's a deliberate choice rather than an oversight.

### Naming consistency across surfaces

Pick one verb and use it everywhere:

| API path                    | UI button | CLI subcommand              |
| --------------------------- | --------- | --------------------------- |
| `POST /conversations/:id/interrupt` | "Interrupt" | `aod conv interrupt <id>` |
| `POST /conversations/:id/terminate` | "Terminate" | `aod conv terminate <id>` |
| `DELETE /conversations/:id`         | "Delete"    | `aod conv delete <id>`    |
| `POST /conversations/:id/prompts`   | (prompt input) | `aod conv prompt <id>` |

If "interrupt" on the API talks to "stop" on the CLI, fix it now — the cost grows.

## Schema vocabulary

- **Sandbox** — the lifespan of one Sprite. Statuses: `pending → starting → ready → terminated|failed`.
- **Conversation** — one chat with one agent inside one sandbox, optionally bound to one vault. Statuses: `pending → running ⇄ idle → completed|failed|terminated`. Owns turns. v1 keeps Sandbox⇄Conversation 1:1.
- **Turn** — one prompt → exit_code cycle. Statuses: `pending → running → completed|failed|interrupted`.
- **LogEvent** — the firehose. `kind: output` (stdout/stderr from the runtime CLI) or `kind: stage` (lifecycle markers — provision, setup, turn). Integer PK so SSE can use `Last-Event-ID` for resume.
- **Environment** — a sandbox shape: packages, env_vars, repositories, networking, setup_script. Owns baseline `Secrets` (AES-256-GCM at rest).
- **Vault** — a free-floating bag of `VaultSecrets` (same crypto). Picked per-conversation. At sprite spawn, env secrets are merged with vault secrets and **vault wins on key collision**. Use it to switch GitHub identity, run as a teammate, or run as a virtual persona — without redefining the environment.

Don't use the word "session" for any of these. The legacy Python AoD overloaded it (sprite lifespan AND chat history) and that's the naming bug we fixed at the rewrite.

## Sprite naming convention

Every default-named sprite AoD creates is prefixed `aod-` so `Sprites.list_sprites(client, prefix: "aod-")` returns "everything this AoD instance ever made" (the Sprites API has no first-class metadata/labels field — the prefix is our origin marker). Subkinds:

- `aod-conv-<short-id>` — per-conversation sprite (`Conversations.start_conversation`)
- `aod-host-<unix-ts>` — the AoD host itself (`mix aod.up`)

Operator-supplied `sprite_name` overrides bypass the prefix, by design.

## Architecture (one paragraph)

`AgentOnDemand.Conversations.ConversationServer` is the brain — a GenServer per running conversation, supervised by `AgentOnDemand.ConversationSupervisor` (a `DynamicSupervisor`), addressed via `AgentOnDemand.ConversationRegistry`. On start it creates a sprite (`Sprites.create`), mounts bundled skills from `priv/sprite_skills/`, writes runtime-specific config (e.g. claude's `~/.claude.json` for MCP), runs the env's `setup_script`, then spawns the runtime CLI with the prompt on stdin via `Sprites.spawn`. stdout/stderr lines are persisted to `log_events` and broadcast on `Phoenix.PubSub` topic `"conv:<id>"`. SSE controller subscribes + replays from `Last-Event-ID` + live-tails. claude `--resume` uses the session_id captured from claude's stream-json `init` message and persisted to `conversations.runtime_session_id`.

## Things that bite

- `Sprites.spawn` defaults `stdin: false`. If you forget `stdin: true`, claude reads empty stdin and prints "Input must be provided" to stderr. (We always pass it now; mentioned here so you don't try to remove it.)
- sprites-ex sends GenServer messages tagged with `%{ref: ref}`, not the full Command struct. Match on `^current_command_ref` not on the struct.
- LiveView socket comes from CDN (no esbuild pipeline). The CDN URLs are pinned to the resolved hex versions of `phoenix` and `phoenix_live_view`. Bump them when you bump those deps.
- The escript ships a single binary with all deps embedded. SSE uses a `curl -N` Port (httpc's stream-self mode hangs in escript; not worth debugging when curl is universal).
- `AOD_PUBLIC_URL` has to be reachable from inside the sprite for the bundled `aod` skill to work — `localhost` won't do. Use cloudflared in dev, the Render URL in prod.

## Testing & CI

`mix precommit` is the alias to run before pushing — `compile --warnings-as-errors`, format check, deps unused, tests. There aren't many tests yet; the system was driven end-to-end first. When backfilling, the highest-value targets are: ConversationServer state transitions, SSE replay-from-cursor, and the `aod.import` mapper.

## When in doubt

The README has the canonical view of what you can do from each surface. If the README doesn't show something, it doesn't exist yet.
