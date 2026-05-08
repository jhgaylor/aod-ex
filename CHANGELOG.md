# Changelog

Notable changes since the v1 functional baseline ("the four functional gaps closed"). Reverse-chronological — newest at top.

## v0.2.11 — conversation list usability + keyboard shortcuts (2026-05-08)

UI polish patch. Conversation list grew a Task column rendering the first prompt of each conversation (preloaded in one query via `first_turn_query/0`, truncated CSS-only with `table-fixed` so long prompts can't blow out the layout). Sidebar conversation links show first-prompt + metadata. New keyboard shortcuts with a cheatsheet modal; `SubmitOnCmdEnter` hook on the conversation send-prompt textarea. Docs fixes: stale `ravi-hq/agent-on-demand-ex` URLs replaced with `jhgaylor/aod-ex`; Skills page synced from `.claude/skills/aod`; `sync_content.sh` invoked via bash and `mkdir -p`s its target dirs.

## v0.2.10 — `aod shellenv` (2026-05-04)

`aod shellenv --name <sprite-name>` recovers an instance's `AOD_BASE_URL` + `AOD_TOKEN` from its deployed `start.sh` and prints shell exports on stdout. Designed for `eval`:

```bash
eval "$(aod shellenv --name aod-host-1730758800)"
aod conv list   # uses the recovered creds
```

Stdout is exports only (so the eval is safe); the recovery banner goes to stderr. Reuses the same `parse_start_sh` round-trip the `aod up --name` upgrade path already relies on.

## v0.2.9 — skills.sh-shaped skills (2026-05-04)

`agents.skills` is now a list of `{name?, content?, source?}` objects instead of a list of bundled-skill names. Each entry is either inline (`{name, content}` — full SKILL.md text written to the sprite) or github (`{source, name?}` — installed on the sprite via the [skills.sh](https://skills.sh) CLI). The bundled `aod` callback skill is always prepended automatically.

- **Schema** — `agents.skills` column type swapped from `{:array, :string}` to `{:array, :map}`. Changeset enforces "exactly one of `content`/`source`" and "inline requires a name." Data migration `20260504000000_rehydrate_agent_skills.exs` translates `metadata.legacy_skills` (from `mix aod.import`) into the new shape and clears stale string entries.
- **Runtime trait** — added `skills_root/0` + `skills_sh_agent/0` callbacks to `AgentOnDemand.Runtimes`. claude → `claude-code`, codex → `codex`, gemini → `gemini-cli`, opencode → `opencode`. `skills_root` paths reflect each runtime's actual `HOME` on the sprite (`/tmp` for gemini and opencode, `/home/sprite` for claude and codex).
- **Provisioning** — `SpriteSkills.mount/3` rewritten: inline entries → `Filesystem.write` to `<skills_root>/<name>/SKILL.md`; github entries shell out to `npx -y skills@latest add <source> --global --agent <id> --yes [--skill <name>]`. The codex `AGENTS.md` and gemini `GEMINI.md` concatenation paths are gone — skills.sh handles those layouts itself. `safe_token!/1` allow-lists `[A-Za-z0-9._/-]` and raises on shell metacharacters; tested directly against shell-injection inputs.
- **Three surfaces** — OpenAPI schemas updated; LiveView form swapped the comma-text input for a JSON textarea matching the `mcp_servers_json` pattern; `mix aod.import` now translates `{type: "github", source, name?}` directly into the new shape and drops the "won't auto-mount" warning.

## Production polish + remaining runtimes (2026-05-01, second pass)

- **OpenTelemetry stack** — `opentelemetry`, `opentelemetry_phoenix` (auto HTTP spans), `opentelemetry_ecto` (auto DB spans), OTLP exporter. Configured opt-in via `OTEL_EXPORTER_OTLP_ENDPOINT` (no-op when unset). `TRACEPARENT` propagated into the sprite env so claude / codex / gemini / opencode tag their model API calls into our trace.
- **CI on GitHub Actions** running `mix precommit` on push + PR. Cached deps + `_build`. Pinned to the same Elixir/OTP versions render.yaml uses.
- **Credo + Dialyxir** in `mix precommit`. Credo runs `--strict --mute-exit-status` for now (60 stylistic findings to clean up incrementally — none block CI). Dialyzer PLT cached at `priv/plts/`.
- **Codex, Gemini, OpenCode runtimes.** All four runtimes now ported. Codex + Gemini self-manage their conversation state (no session id needed). OpenCode is a multi-provider front; `default_env/1` picks ANTHROPIC/OPENAI/GEMINI key based on the model's provider prefix.

## Overnight resilience pass (2026-05-01)

The user's "durable, well tested, clusterable, observability, audit log, rate limiting" priorities, taken end to end. Each item below is its own commit.

### Durability

- **Boot rehydration + reattach to existing sprites.** On app start, scan `idle`/`running` conversations with `ready` sandboxes and restart `ConversationServer`s for each. The server reattaches: gets the sprite handle without recreating, checks it's alive at sprites.dev, lists active detachable runtime sessions, attaches if any. Falls back to marking the orphaned turn `interrupted` if the sprite is still up but the runtime command finished while we were down.
- **Detachable runtime spawns.** `Sprites.spawn` now passes `detachable: true` so the sprite-side session survives WebSocket disconnects. This is what makes mid-turn-crash recovery work.
- **`wake_conversation` reuses healthy sandboxes.** Previously every wake created a fresh sprite; now if the existing sandbox is `ready` and the sprite is alive, we just start a server pointed at it.
- **Sprite checkpoint/restore on environments.** After a successful fresh provision, async-create a sprites.dev checkpoint of the post-`setup_script` state. Persist the id on the env. Subsequent conversations on the same env warm-start from the checkpoint (~100ms) instead of redoing apt/git/setup_script (~30s+). Auto-invalidates on env changes that affect provisioning.
- **`.env` file written into the sprite.** Merged sprite env (default + callback + env_vars + secrets) lands at `/home/sprite/.env` (chmod 600). `setup_script`s that `source .env` work as expected.

### Tests

- **11 StreamData properties** on Crypto round-trip + tamper detection, shell-quoting (round-trips through real bash), token redaction, token URL injection, SSE parser (split-across-feeds recovery).
- **157 example tests** covering: schemas + changesets, contexts (env/secret/agent/conv CRUD + decrypted_env + wake_conversation reuse vs. fresh), `Provisioning` step modules + helpers, `ConversationServer` state transitions (provision happy + 3 failure paths, reattach 4 paths, send_prompt + terminate), web controllers + auth, CLI SSE parser.
- **Test infra**: Mimic for the sprites SDK + `Horde.DynamicSupervisor` (no adapter behaviour layer), `AgentOnDemand.Factory` accepting kw lists or maps, `authed/login/post_json/put_json` helpers in ConnCase, async checkpoint creation gated off in tests so spawned tasks don't outlive the Ecto sandbox.

### Clusterable

- **`libcluster` + `Horde`.** `Registry` and `DynamicSupervisor` swapped for `Horde.Registry` and `Horde.DynamicSupervisor` with `members: :auto`. Single-node behavior unchanged; on connected nodes the CRDT-replicated registry+supervisor sync state cluster-wide. `libcluster` wired with DNSPoll strategy gated on `CLUSTER_DNS_QUERY` (empty default = single node).

### Observability

- **Telemetry scaffold**: `AgentOnDemand.Telemetry` over `:telemetry.span/3` + `execute/3` under an `:agent_on_demand` prefix. Default JSON logger handler attached at boot. Portable surface — operators attach `OpentelemetryTelemetry` to map spans onto OTel later without us locking the app to the OTel runtime.

### Audit log

- **`audit_events` table + `Plugs.Audit`.** Every state-changing API call (`POST/PUT/PATCH/DELETE`) on `:authed_api` records: action, resource type/id, actor (`"api"`), client IP, response status, timestamp. `/audit` LiveView page (5s autorefresh, mono table) lives in the sidebar. Append-only — append failures never break the operation they're recording.

### Rate limiting

- **`Plugs.RateLimit`** per-IP ETS bucket, 600 req/min on `:authed_api`, returns `429` with `Retry-After`. Idempotent table init so the plug works in tests + ad-hoc Mix tasks without explicit boot.

### Misc

- **OpenAPI Create-vs-Update split**. `Schemas.AgentUpdate` + `Schemas.EnvironmentUpdate` (all-optional) on PUT routes. Re-enables partial updates that `OpenApiSpex.Plug.CastAndValidate` was rejecting.
- **SSH-based git clone.** Repository specs accept `ssh://…` and `git@host:owner/repo` URLs; private key from an env secret named by `ssh_key_secret` is written per-clone, used via `GIT_SSH_COMMAND`, then deleted on exit. `StrictHostKeyChecking=no` (defensible inside a fresh sprite — no MITM surface).
- **Operator runbook** at `docs/runbook.md`. Covers `ADMIN_TOKEN` + `SECRETS_KEY` rotation (incl. the manual re-encrypt), unsticking conversations, orphan-sprite cleanup, rate-limit overflow, audit GC, SQLite backup/restore, BEAM crash recovery semantics, multi-node deploy.

### Deferred

- **#33 SSE controller integration tests.** Chunked-transfer encoding has no clean `Phoenix.ConnTest` helper. The underlying behavior (`list_log_events` with cursor) is already covered in contexts_test.
- **Oban worker durability.** Decided against. Boot rehydration + `Sprites.list_sessions/attach_session` for in-flight commands already covers the same failure space; adding Oban would be ceremony for marginal benefit. Reopen if we want job-style retries on the runtime spawn itself.

## v1 baseline

Initial commit. Phoenix + SQLite + sprites-ex Elixir rewrite of `ravi-hq/agent-on-demand`. API + LiveView UI + escript CLI. Closed the original four functional gaps (skills filtering, package install, network policy, GitHub repo mounting).
