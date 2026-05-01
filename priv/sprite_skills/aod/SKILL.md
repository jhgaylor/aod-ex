---
name: aod
description: Spawn and stream Agent on Demand (AoD) conversations — for when this agent needs to fan out work to other coding agents. Use when the user asks you to "delegate to another agent", "spawn an agent", "fan out", or when a task is large enough to warrant parallel agents working in parallel sandboxes. AoD provisions an isolated Sprite, runs a configured agent in it, and streams output back over SSE. Reads `AOD_BASE_URL` and `AOD_TOKEN` from the environment.
---

# Agent on Demand (AoD) — From Inside a Sprite

You are running inside a Sprite that AoD provisioned. AoD itself is reachable at
`$AOD_BASE_URL` with bearer `$AOD_TOKEN`. From here you can spawn *more* AoD
conversations — each one runs in its own fresh Sprite.

## When to spawn another agent

- A subtask is genuinely independent and parallelizable (e.g. "audit each of
  these 12 services for X"). Spawn one conversation per service.
- You need a different runtime or model (e.g. delegate codegen to Claude,
  reasoning to GPT-o3) for one part of the task.
- The user explicitly asks you to delegate.

Do **not** spawn another agent for trivial subtasks you can do yourself — each
spawn provisions a real sandbox with real cost.

## API at a glance

All requests need `Authorization: Bearer $AOD_TOKEN`.

```bash
# 1. Pick or create an agent definition
curl -s "$AOD_BASE_URL/agents" -H "Authorization: Bearer $AOD_TOKEN"

# Or create one
curl -s -X POST "$AOD_BASE_URL/agents" \
  -H "Authorization: Bearer $AOD_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "subagent-research",
    "model": "anthropic/claude-sonnet-4-6",
    "runtime": "claude",
    "system": "You are a focused research subagent..."
  }'

# 2. Start a conversation (provisions a sprite + queues turn 1)
CONV=$(curl -s -X POST "$AOD_BASE_URL/conversations" \
  -H "Authorization: Bearer $AOD_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"agent_id\":\"$AGENT_ID\",\"prompt\":\"Investigate X and report.\"}" \
  | jq -r .data.id)

# 3. Stream output (SSE — one stream-json line per claude assistant message)
curl -N -s "$AOD_BASE_URL/conversations/$CONV/stream" \
  -H "Authorization: Bearer $AOD_TOKEN"

# 4. Optional: send another prompt (turn 2+; resumes the agent's context)
curl -s -X POST "$AOD_BASE_URL/conversations/$CONV/prompts" \
  -H "Authorization: Bearer $AOD_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"prompt":"What did you find about Y specifically?"}'

# 5. Tear it down (destroys the sprite)
curl -s -X POST "$AOD_BASE_URL/conversations/$CONV/terminate" \
  -H "Authorization: Bearer $AOD_TOKEN"
```

## SSE stream format

Each line group in the stream is one event:

```
id: <int>
event: stage|output
data: {"kind": "...", "stream": "stdout|stderr", "data": "<json line from runtime>", ...}
```

For `event: output` from the `claude` runtime, the `data.data` payload is one
line of stream-json — parse the inner JSON to find `type=assistant` for the
text the model emitted. `event: stage` events mark provisioning, turn boundaries,
and termination.

If the connection drops, reconnect with `Last-Event-ID: <last-id-seen>` to
resume without replay loss.

## Patterns

**Fan out N parallel investigations:**

```bash
for service in api worker scheduler; do
  curl -s -X POST "$AOD_BASE_URL/conversations" \
    -H "Authorization: Bearer $AOD_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"agent_id\":\"$RESEARCHER\",\"prompt\":\"Audit $service\"}" \
    | jq -r .data.id
done > /tmp/conv_ids.txt
# then tail the streams, gather results
```

**Aggregate results:** stream each conversation, parse the final
`type=result` line of the claude stream-json to get the assistant's
final answer.

## Important

- **Don't recurse forever.** Spawned agents have the same skill; cap depth
  with a `MAX_DEPTH` you check before spawning, or set per-spawn timeouts.
- **Costs add up.** Every conversation provisions a real sandbox. Terminate
  when done.
- **Same `$AOD_TOKEN`.** All spawned agents share the single-tenant admin
  token in this environment. Don't leak it outside the sprite.
