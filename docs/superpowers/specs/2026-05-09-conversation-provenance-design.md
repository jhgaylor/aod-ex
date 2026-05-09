# Conversation Provenance Design

**Date:** 2026-05-09
**Status:** Approved
**Branch:** feat/conversation-provenance

## Problem

Conversations can be started from three surfaces: the web UI, a direct API/curl call, or the bundled `aod` skill running inside another sprite (which itself calls `POST /api/conversations`). Currently nothing distinguishes these — there is no way to know what triggered a conversation or reconstruct the chain of parent → child spawns.

## Goal

Track the full provenance chain for every conversation:
- What initiated it (`ui`, `api`, or `agent`)
- Which conversation spawned it, if any (`parent_conversation_id`)

This lets you reconstruct a tree of agent-spawned conversations and understand whether a session came from a human or a machine.

## Approach: Header-based inference + two DB columns

### 1. Data Model

Two new columns on the `conversations` table:

| Column | Type | Constraints | Default |
|--------|------|-------------|---------|
| `source` | `string` | not null | `"api"` |
| `parent_conversation_id` | `binary_id` (UUID) | nullable, FK → `conversations.id` | `nil` |

**Migration:** `20260509000000_add_provenance_to_conversations.exs`

**Schema additions** (`conversation.ex`):
- `field :source, :string, default: "api"`
- `field :parent_conversation_id, :binary_id`
- `belongs_to :parent_conversation, __MODULE__, foreign_key: :parent_conversation_id, references: :id, type: :binary_id`
- `has_many :child_conversations, __MODULE__, foreign_key: :parent_conversation_id`
- Validation: `source` must be one of `["ui", "api", "agent"]`

The `source` default of `"api"` means existing rows are not broken and no backfill is needed.

### 2. Source Inference

Source is inferred at the call site — not from a caller-supplied field — so it cannot be spoofed:

| Call surface | How detected | `source` value |
|---|---|---|
| LiveView form (`/conversations/new`) | Calls `Conversations.start_conversation/1` directly with `source: "ui"` | `"ui"` |
| Direct API / curl (no parent header) | `ConversationController.create/2`, no `X-AoD-Parent-Conversation-Id` header | `"api"` |
| AoD skill inside a sprite | `ConversationController.create/2`, `X-AoD-Parent-Conversation-Id` header present | `"agent"` |

### 3. HTTP Header

When the API controller receives `POST /api/conversations`, it reads:

```
X-AoD-Parent-Conversation-Id: <uuid>
```

If present → `source = "agent"`, `parent_conversation_id = <uuid>`
If absent  → `source = "api"`, `parent_conversation_id = nil`

### 4. Automatic Propagation via Env Var

When `ConversationServer` provisions a sprite, it already builds a map of env vars to inject. We add:

```
AOD_CONVERSATION_ID=<current conversation UUID>
```

This is injected alongside the existing env/vault secrets at sprite spawn time.

### 5. AoD Skill Update

`priv/sprite_skills/aod/SKILL.md` is updated so that every `POST /api/conversations` curl example includes:

```bash
-H "X-AoD-Parent-Conversation-Id: $AOD_CONVERSATION_ID"
```

Because `AOD_CONVERSATION_ID` is always present in the sprite's environment, agents automatically propagate the chain without needing to reason about it.

### 6. API Response

`source` and `parent_conversation_id` are included in the conversation JSON response (in the controller's JSON rendering). No new endpoint is needed — callers can walk the chain by following `parent_conversation_id` links.

### 7. UI Changes

- **Conversation list:** small source badge (`UI` / `API` / `Agent`) in the table row
- **Conversation detail:** 
  - Source badge near the top
  - If `parent_conversation_id` is set: a "Spawned by" link to the parent conversation
  - A "Spawned conversations" section listing `child_conversations` (if any)

## Data Flow

```
User clicks "New Conversation" in browser
  → LiveView new.ex calls Conversations.start_conversation(..., source: "ui")
  → conversation.source = "ui", parent_conversation_id = nil

curl POST /api/conversations
  → ConversationController.create (no X-AoD-Parent-Conversation-Id header)
  → conversation.source = "api", parent_conversation_id = nil

Agent inside sprite runs aod skill → curl POST /api/conversations \
  -H "X-AoD-Parent-Conversation-Id: $AOD_CONVERSATION_ID"
  → ConversationController.create (header present)
  → conversation.source = "agent", parent_conversation_id = <parent UUID>
```

## Files Changed

| File | Change |
|------|--------|
| `priv/repo/migrations/20260509000000_add_provenance_to_conversations.exs` | New migration |
| `lib/agent_on_demand/conversations/conversation.ex` | Add fields, associations, validation |
| `lib/agent_on_demand/conversations.ex` | Thread `source` + `parent_conversation_id` through `start_conversation` |
| `lib/agent_on_demand_web/controllers/conversation_controller.ex` | Read header, derive source, pass to context |
| `lib/agent_on_demand/conversations/conversation_server.ex` | Inject `AOD_CONVERSATION_ID` env var at sprite provision time |
| `apps/agent_on_demand/priv/sprite_skills/aod/SKILL.md` | Add header to all POST /api/conversations curl examples |
| `lib/agent_on_demand_web/live/conversations_live/new.ex` | Pass `source: "ui"` |
| `lib/agent_on_demand_web/live/conversations_live/index.ex` | Source badge in table |
| `lib/agent_on_demand_web/live/conversations_live/show.ex` | Source badge, parent link, child list |

## Non-Goals

- Backfilling `source` for existing conversations (they stay `"api"` by default — close enough)
- A dedicated `/api/conversations/:id/chain` endpoint (walk `parent_conversation_id` client-side)
- Tracking CLI as a distinct source (CLI calls the API just like curl; `"api"` is correct for now)
