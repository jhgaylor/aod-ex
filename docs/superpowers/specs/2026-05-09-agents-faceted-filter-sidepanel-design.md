# Agents Faceted Filter Sidepanel

**Date:** 2026-05-09
**Status:** Approved

## Goal

Add a persistent left-side filter panel to the agents list page so users can quickly narrow down agents by runtime, environment, capabilities, and name search — without leaving the page.

## Current State

`AgentsLive.Index` renders a full-width table of all agents sorted by `inserted_at desc`. There is no search or filtering of any kind. `Agents.list_agents/0` returns the full list unconditionally.

## Design

### Layout

The page changes from a single-column layout to a two-column flex layout:

```
┌─────────────────────────────────────────────────┐
│  Agents                          + New agent     │
├──────────────┬──────────────────────────────────┤
│  Filter      │  Name  Runtime  Model  Env  …     │
│  ──────      │  ──────────────────────────────── │
│  Search      │  Row                              │
│  [________]  │  Row                              │
│              │  Row                              │
│  Runtime     │                                   │
│  □ claude 3  │                                   │
│  □ codex  1  │                                   │
│  □ gemini 0  │                                   │
│  □ opencode0 │                                   │
│              │                                   │
│  Environment │                                   │
│  □ None   2  │                                   │
│  □ prod   2  │                                   │
│              │                                   │
│  Extras      │                                   │
│  □ Has skills│                                   │
│  □ Has MCP   │                                   │
│              │                                   │
│  Clear all   │                                   │
└──────────────┴──────────────────────────────────┘
```

The sidebar is `w-52 shrink-0`. The table area is `flex-1 min-w-0`.

### Facets

| Facet | Type | Field | Notes |
|---|---|---|---|
| Search | text input | `name` | Case-insensitive substring (`ilike`) |
| Runtime | multi-checkbox | `runtime` | One checkbox per known runtime value; shows count |
| Environment | multi-checkbox | `environment_id` | One checkbox per env + "No environment"; shows count |
| Has Skills | single checkbox | `skills` | Filters to agents where `skills != []` |
| Has MCP Servers | single checkbox | `mcp_servers` | Filters to agents where `mcp_servers != {}` |

Facet counts come from the **full unfiltered** agent set — computed once on mount. Counts are stable regardless of active filters, giving the user a clear picture of their total inventory.

A "Clear all" link appears below the facets only when at least one filter is active.

### Filter State in Socket Assigns

```elixir
%{
  filter_search: "",          # string
  filter_runtimes: [],        # list of selected runtime strings e.g. ["claude", "codex"]
  filter_env_ids: [],         # list of selected env IDs + sentinel "none" string
  filter_has_skills: false,   # boolean
  filter_has_mcp: false,      # boolean
  facet_counts: %{...},       # computed once on mount, never changes
  all_environments: [...],    # list of Environment structs for sidebar labels
  agents: [...]               # filtered result, re-assigned on each filter change
}
```

### Data Flow

```
mount/3
  ├── Agents.list_agents()              → facet_counts, all_environments
  └── Agents.list_agents([])            → agents (full list initially)

handle_event("filter", params, socket)
  ├── parse params → filter state
  ├── Agents.list_agents(filters)       → agents (filtered)
  └── assign updated filter state + agents

handle_event("clear_filters", _, socket)
  └── reset all filter state + Agents.list_agents([])
```

### Backend Changes

`Agents.list_agents/1` gains an optional `filters` keyword list parameter. Each filter is applied as an additional `where` clause to the base query:

- `search: "foo"` → `ilike(a.name, "%foo%")`
- `runtimes: ["claude"]` → `a.runtime in ["claude"]` (skipped if empty)
- `env_ids: ["<uuid>"]` → `a.environment_id in [<uuid>]` (skipped if empty; `"none"` maps to `is_nil(a.environment_id)`)
- `has_skills: true` → `fragment("json_array_length(?) > 0", a.skills)`
- `has_mcp: true` → `fragment("? != '{}'", a.mcp_servers)`

A separate `Agents.agent_facets/0` function returns pre-computed counts:

```elixir
%{
  runtimes: %{"claude" => 3, "codex" => 1, ...},
  env_ids: %{"none" => 2, "<uuid>" => 2, ...}
}
```

This is a single pass over the full agent list — no extra DB queries.

### UI Interaction

- Filter inputs are wrapped in a `<form phx-change="filter" phx-submit="filter">`. The `phx-change` fires on every keystroke/checkbox toggle, immediately re-filtering.
- Runtime checkboxes use `name="runtimes[]"` so Phoenix params deliver a list.
- Environment checkboxes use `name="env_ids[]"` similarly.
- Boolean checkboxes use `name="has_skills"` and `name="has_mcp"`.
- The search input has `phx-debounce="200"` to avoid excessive re-renders on fast typing.
- When the filtered list is empty and filters are active, a message explains no agents match (not the "No agents yet" empty state, which only appears when there are literally zero agents).

## Files Changed

1. `apps/agent_on_demand/lib/agent_on_demand/agents.ex`
   - Add `list_agents/1` with dynamic filtering
   - Add `agent_facets/0`

2. `apps/agent_on_demand/lib/agent_on_demand_web/live/agents_live/index.ex`
   - Add filter assigns to `mount/3`
   - Add `handle_event("filter", ...)`
   - Add `handle_event("clear_filters", ...)`
   - Restructure `render/1` to two-column layout with filter sidebar

## Non-Goals

- Pagination (separate concern)
- Filtering by model text (model strings are not enumerable without extra query; name search covers most discovery needs)
- Persisting filter state across page reloads
- URL-based filter state (nice-to-have but out of scope)
