# How it works

The 5-minute version of what happens when you call `POST /api/conversations`.

## Architecture, in one paragraph

A `ConversationServer` GenServer owns each running conversation, supervised by a Horde-replicated `DynamicSupervisor` so they survive node loss in a cluster. On start it provisions a Sprite microVM, mounts bundled skills, writes runtime-specific config, runs the environment's setup script, then spawns the runtime CLI (claude / codex / gemini / opencode) with the prompt on stdin. stdout/stderr lines persist to a `log_events` table and broadcast on a Phoenix.PubSub topic. The SSE controller subscribes, replays from `Last-Event-ID`, and live-tails. Multi-turn `--resume` uses the runtime's own session id captured from its init line.

That's the whole system. Below is each piece.

## The objects

```
Environment ──► describes what a sprite looks like
                (packages, env vars, networking, repos, setup_script)

Agent ──────► references one Environment + a runtime + a model
                (skills, mcp_servers, system prompt)

Conversation ──► one chat with one Agent inside one Sandbox
                (status: pending → running ⇄ idle → completed/failed/terminated)

Sandbox ─────► one running Sprite microVM
                (status: pending → starting → ready → terminated/failed)

Turn ────────► one prompt → exit_code cycle
                (multiple turns per Conversation; status tracks the in-flight one)

LogEvent ────► one line of stdout/stderr OR one stage marker
                (integer PK so SSE clients can use Last-Event-ID for resume)
```

A turn is what an LLM provider would call a "request." A conversation holds many turns; the runtime CLI's session resume keeps the agent's context intact across them.

## Provisioning a sprite

When a conversation kicks off:

1. **Stage `provision started`.** A new Sprite is created via the sprites.dev API.
2. **Skills mounted.** Bundled skills under `priv/sprite_skills/<name>/` get copied into the sprite at `~/.claude/skills/<name>/SKILL.md` (claude/opencode read these natively; codex and gemini get a concatenated `AGENTS.md`/`GEMINI.md`).
3. **Runtime config written.** Each runtime has a `write_config/2` callback that writes its native MCP config: claude → `~/.claude.json`, codex → `~/.codex/config.toml`, gemini → `~/.gemini/settings.json`, opencode → `~/.config/opencode/opencode.json`. Same agent.mcp_servers map; four different on-disk shapes.
4. **Per-runtime bootstrap.** A `prepare_sprite/3` callback handles runtime-specific quirks. Codex needs `codex login --with-api-key` (it doesn't read `OPENAI_API_KEY` at exec time). Opencode isn't on the default sprite image — `bun install -g opencode-ai` and symlink onto PATH. Gemini needs a workspace dir with `.git` so its MemoryDiscovery doesn't trip.
5. **Provisioning pipeline.** Packages installed via apt, network policy applied if scoped, repositories cloned (with `XDG_CONFIG_HOME=/tmp` so git's user-scope ignore doesn't fight ACLs), setup script run.
6. **Stage `provision done`.** Optionally captures a sprite checkpoint so subsequent conversations on the same environment warm-start in milliseconds instead of seconds.

Every stage emits a `started` and `done` (or `failed`) `LogEvent`. Output emitted while a stage is active gets tagged with the stage name on the LogEvent itself, so the UI groups it under the right card and the API consumer can filter.

## Running a turn

Once the sandbox is `ready`:

1. **Stage `turn started`.** A `Turn` row is inserted; its id gets stamped on every output event for the duration.
2. **Runtime CLI spawned.** The runtime module's `build_command/5` returns argv, plus opts like `stdin?` (does the prompt go on stdin?) and `tty?` (allocate a PTY?). For codex, `tty?: true` to satisfy `isatty(0)` and silence its stdin warning.
3. **Output streams.** The CLI's stdout/stderr lines flow back over the sprite's WebSocket, get persisted as `LogEvent` rows with `kind: "output"`, and broadcast on `"conv:<id>"` so any SSE subscriber sees them in real time.
4. **For runtimes that emit stream-json**, the runtime's session id is parsed from the first `init` event and persisted on the conversation row. That's what powers multi-turn `--resume`.
5. **Stage `turn done`.** The `:exit` message from the runtime CLI flips the turn to `completed`/`failed`, the conversation back to `idle`, and closes the OTel span we opened in step 1.

## Surviving a server crash

The sprite is detachable. If the BEAM dies mid-turn:

- The conversation's status stays `running` in the DB.
- The Turn stays `running` too.
- The sprite-side runtime CLI keeps executing (it's not bound to our WebSocket — Sprites' detachable sessions persist).
- On boot, the rehydrator walks resumable conversations (status in `idle`/`running`, sandbox `ready`), spawns a `ConversationServer` for each, which calls `list_sessions` on its sprite and `attach_session` if it finds the still-alive exec.
- The server replays buffered output (deduped by byte count against what we already persisted), then live-tails the rest.
- The eventual `:exit` closes the turn cleanly.

End user sees a brief gap on the SSE stream and the conversation completes normally. No re-prompting, no double-billing.

## Sub-agent spawning

Every sprite gets `AOD_BASE_URL` + `AOD_TOKEN` in its env and the bundled `aod` skill mounted. From inside a sprite, an agent can call back to the API and spawn more conversations. Patterns:

- **Fan-out**: parent agent spawns N children in parallel, polls them until done, gathers their final answers.
- **Delegation**: send a sub-task to a different runtime. Codegen → claude. Reasoning → codex.
- **Hierarchical planning**: a planning agent breaks down a big task, fans out research, synthesizes back.

The same security model applies: the sprite has the admin token. Prompt injection inside an agent is a privilege escalation. Scoped child tokens are on the roadmap.

## Observability

- **OTel spans** wrap every stage and every turn. TRACEPARENT propagates into the sprite env, so the runtime CLI's API calls to its provider land as child spans. Send to any OTLP backend.
- **Audit log**: state-changing API calls (POST/PUT/DELETE) get persisted to an `audit_events` table.
- **Per-IP rate limiting** with ETS, default 600/min on `/api/*`.
- **The LiveView UI** renders all of the above in real time — stage cards with timing, tool call cards with results paired in, chat-style view for end-user-friendly summaries.

## What's deliberately not here

- Hosted AoD. You self-host.
- Multi-tenant scoping. Single admin token; if you want per-customer isolation, run multiple instances or wait for scoped child tokens.
- A chatbot UI. The LiveView is for *operators* watching the agents work.
- Sprite-internals abstraction. We're betting on Sprites; if you want a different VM provider, this isn't the project.

[Install it →](install.md){ .md-button .md-button--primary }
[Read the API →](concepts/api.md){ .md-button }
