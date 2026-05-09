# Agents Faceted Filter Sidepanel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a persistent left-side filter panel to the agents list page with faceted filtering by runtime, environment, skills, and MCP server presence, plus a name search input.

**Architecture:** `Agents.list_agents/1` gains an optional keyword-list `filters` parameter that builds a dynamic Ecto query; facet counts are computed in-memory from the full unfiltered list on mount. The LiveView tracks filter state as socket assigns and re-queries on every `phx-change` event from a filter form in the sidebar. The page layout becomes a two-column flex: narrow sidebar left, existing table right.

**Tech Stack:** Elixir, Phoenix LiveView, Ecto, SQLite3 (via `ecto_sqlite3`), TailwindCSS, Heex templates

---

## File Map

| File | Change |
|---|---|
| `apps/agent_on_demand/lib/agent_on_demand/agents.ex` | Add `list_agents/1` (default arg keeps `list_agents/0` working), add private filter helpers |
| `apps/agent_on_demand/lib/agent_on_demand_web/live/agents_live/index.ex` | Add filter assigns, filter event handlers, restructured two-column render |
| `apps/agent_on_demand/test/agent_on_demand/agents_test.exs` | New: tests for `list_agents/1` filter behaviour |

---

## Task 1: Extend `Agents.list_agents/1` with dynamic filtering

**Files:**
- Modify: `apps/agent_on_demand/lib/agent_on_demand/agents.ex`
- Create: `apps/agent_on_demand/test/agent_on_demand/agents_test.exs`

- [ ] **Step 1: Write failing tests**

Create `apps/agent_on_demand/test/agent_on_demand/agents_test.exs`:

```elixir
defmodule AgentOnDemand.AgentsTest do
  use AgentOnDemand.DataCase, async: true

  alias AgentOnDemand.Agents

  defp create_agent(attrs) do
    defaults = %{
      "name" => "agent-#{System.unique_integer([:positive])}",
      "model" => "anthropic/claude-sonnet-4-6",
      "runtime" => "claude"
    }

    {:ok, agent} = Agents.create_agent(Map.merge(defaults, attrs))
    agent
  end

  describe "list_agents/1" do
    test "returns all agents when no filters" do
      a = create_agent(%{})
      b = create_agent(%{})
      ids = Agents.list_agents() |> Enum.map(& &1.id)
      assert a.id in ids
      assert b.id in ids
    end

    test "filters by search (case-insensitive substring on name)" do
      _other = create_agent(%{"name" => "zz-unrelated"})
      match = create_agent(%{"name" => "My Cool Agent"})

      results = Agents.list_agents(search: "cool")
      assert Enum.any?(results, & &1.id == match.id)
      refute Enum.any?(results, & &1.name == "zz-unrelated")
    end

    test "filters by runtime" do
      claude = create_agent(%{"runtime" => "claude"})
      codex  = create_agent(%{"runtime" => "codex"})

      results = Agents.list_agents(runtimes: ["claude"])
      assert Enum.any?(results, & &1.id == claude.id)
      refute Enum.any?(results, & &1.id == codex.id)
    end

    test "returns all when runtimes filter is empty list" do
      a = create_agent(%{})
      results = Agents.list_agents(runtimes: [])
      assert Enum.any?(results, & &1.id == a.id)
    end

    test "filters to agents with no environment when env_ids includes 'none'" do
      no_env = create_agent(%{})
      results = Agents.list_agents(env_ids: ["none"])
      assert Enum.any?(results, & &1.id == no_env.id)
    end

    test "filters by has_skills" do
      with_skills = create_agent(%{
        "name" => "skilled-#{System.unique_integer([:positive])}",
        "skills" => [%{"name" => "test", "content" => "# SKILL\n"}]
      })
      bare = create_agent(%{"name" => "bare-#{System.unique_integer([:positive])}"})

      results = Agents.list_agents(has_skills: true)
      assert Enum.any?(results, & &1.id == with_skills.id)
      refute Enum.any?(results, & &1.id == bare.id)
    end

    test "filters by has_mcp" do
      with_mcp = create_agent(%{
        "name" => "mcp-#{System.unique_integer([:positive])}",
        "mcp_servers" => %{"my_server" => %{"command" => "npx foo"}}
      })
      bare = create_agent(%{"name" => "nomcp-#{System.unique_integer([:positive])}"})

      results = Agents.list_agents(has_mcp: true)
      assert Enum.any?(results, & &1.id == with_mcp.id)
      refute Enum.any?(results, & &1.id == bare.id)
    end
  end
end
```

- [ ] **Step 2: Run tests to confirm they fail as expected**

```bash
cd apps/agent_on_demand && mix test test/agent_on_demand/agents_test.exs
```

Expected: compile errors or test failures — `list_agents/1` with keyword args doesn't exist yet.

- [ ] **Step 3: Implement `list_agents/1` with filter helpers**

Replace the existing `list_agents/0` in `apps/agent_on_demand/lib/agent_on_demand/agents.ex`:

```elixir
def list_agents(filters \\ []) do
  from(a in Agent, order_by: [desc: a.inserted_at, desc: a.id], preload: [:environment])
  |> apply_search(Keyword.get(filters, :search, ""))
  |> apply_runtimes(Keyword.get(filters, :runtimes, []))
  |> apply_env_ids(Keyword.get(filters, :env_ids, []))
  |> apply_has_skills(Keyword.get(filters, :has_skills, false))
  |> apply_has_mcp(Keyword.get(filters, :has_mcp, false))
  |> Repo.all()
end
```

Add private filter helpers at the bottom of the module (before the closing `end`):

```elixir
defp apply_search(query, ""), do: query

defp apply_search(query, search) do
  term = "%#{search}%"
  from a in query, where: like(a.name, ^term)
end

defp apply_runtimes(query, []), do: query

defp apply_runtimes(query, runtimes) do
  from a in query, where: a.runtime in ^runtimes
end

defp apply_env_ids(query, []), do: query

defp apply_env_ids(query, env_ids) do
  {none, real_ids} = Enum.split_with(env_ids, &(&1 == "none"))

  cond do
    none != [] and real_ids != [] ->
      from a in query,
        where: is_nil(a.environment_id) or a.environment_id in ^real_ids

    none != [] ->
      from a in query, where: is_nil(a.environment_id)

    true ->
      from a in query, where: a.environment_id in ^real_ids
  end
end

defp apply_has_skills(query, false), do: query

defp apply_has_skills(query, true) do
  from a in query, where: fragment("json_array_length(?)", a.skills) > 0
end

defp apply_has_mcp(query, false), do: query

defp apply_has_mcp(query, true) do
  from a in query, where: fragment("? != '{}'", a.mcp_servers)
end
```

- [ ] **Step 4: Run tests to confirm they pass**

```bash
cd apps/agent_on_demand && mix test test/agent_on_demand/agents_test.exs
```

Expected: all tests in `AgentOnDemand.AgentsTest` pass.

- [ ] **Step 5: Commit**

```bash
git add apps/agent_on_demand/lib/agent_on_demand/agents.ex \
        apps/agent_on_demand/test/agent_on_demand/agents_test.exs
git commit -m "feat: add dynamic filtering to Agents.list_agents/1"
```

---

## Task 2: Update `AgentsLive.Index` with filter state and sidebar

**Files:**
- Modify: `apps/agent_on_demand/lib/agent_on_demand_web/live/agents_live/index.ex`

- [ ] **Step 1: Replace the full content of `index.ex`**

Replace `apps/agent_on_demand/lib/agent_on_demand_web/live/agents_live/index.ex` with:

```elixir
defmodule AgentOnDemandWeb.AgentsLive.Index do
  use AgentOnDemandWeb, :live_view

  alias AgentOnDemand.Agents
  alias AgentOnDemand.Agents.Agent

  @impl true
  def mount(_params, _session, socket) do
    all_agents = Agents.list_agents()

    {:ok,
     socket
     |> assign(:page_title, "Agents")
     |> assign(:agents, all_agents)
     |> assign(:facet_counts, compute_facets(all_agents))
     |> assign(:all_environments, extract_environments(all_agents))
     |> assign(:filter_search, "")
     |> assign(:filter_runtimes, [])
     |> assign(:filter_env_ids, [])
     |> assign(:filter_has_skills, false)
     |> assign(:filter_has_mcp, false)}
  end

  @impl true
  def handle_event("filter", params, socket) do
    search = params |> Map.get("search", "") |> String.trim()
    runtimes = Map.get(params, "runtimes", [])
    env_ids = Map.get(params, "env_ids", [])
    has_skills = Map.has_key?(params, "has_skills")
    has_mcp = Map.has_key?(params, "has_mcp")

    filters = [
      search: search,
      runtimes: runtimes,
      env_ids: env_ids,
      has_skills: has_skills,
      has_mcp: has_mcp
    ]

    {:noreply,
     socket
     |> assign(:filter_search, search)
     |> assign(:filter_runtimes, runtimes)
     |> assign(:filter_env_ids, env_ids)
     |> assign(:filter_has_skills, has_skills)
     |> assign(:filter_has_mcp, has_mcp)
     |> assign(:agents, Agents.list_agents(filters))}
  end

  @impl true
  def handle_event("clear_filters", _params, socket) do
    {:noreply,
     socket
     |> assign(:filter_search, "")
     |> assign(:filter_runtimes, [])
     |> assign(:filter_env_ids, [])
     |> assign(:filter_has_skills, false)
     |> assign(:filter_has_mcp, false)
     |> assign(:agents, Agents.list_agents())}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    agent = Agents.get_agent!(id)
    {:ok, _} = Agents.delete_agent(agent)

    all_agents = Agents.list_agents()
    filters = current_filters(socket.assigns)

    {:noreply,
     socket
     |> assign(:agents, Agents.list_agents(filters))
     |> assign(:facet_counts, compute_facets(all_agents))
     |> assign(:all_environments, extract_environments(all_agents))
     |> put_flash(:info, "Deleted #{agent.name}")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex gap-6 items-start">
      <%!-- Filter sidebar --%>
      <aside class="w-52 shrink-0 space-y-5">
        <form phx-change="filter" phx-submit="filter" class="space-y-5">
          <%!-- Search --%>
          <div>
            <p class="text-xs font-semibold text-zinc-500 uppercase tracking-wide mb-1.5">Search</p>
            <input
              type="text"
              name="search"
              value={@filter_search}
              phx-debounce="200"
              placeholder="Agent name…"
              class="w-full rounded border border-zinc-300 px-2 py-1 text-sm focus:outline-none focus:border-zinc-500 bg-white"
            />
          </div>

          <%!-- Runtime facet --%>
          <div>
            <p class="text-xs font-semibold text-zinc-500 uppercase tracking-wide mb-1.5">Runtime</p>
            <div class="space-y-1.5">
              <label :for={rt <- Agent.runtimes()} class="flex items-center justify-between gap-2 text-sm cursor-pointer">
                <span class="flex items-center gap-1.5">
                  <input
                    type="checkbox"
                    name="runtimes[]"
                    value={rt}
                    checked={rt in @filter_runtimes}
                    class="rounded border-zinc-300"
                  />
                  {rt}
                </span>
                <span class="text-xs text-zinc-400">{Map.get(@facet_counts.runtimes, rt, 0)}</span>
              </label>
            </div>
          </div>

          <%!-- Environment facet --%>
          <div>
            <p class="text-xs font-semibold text-zinc-500 uppercase tracking-wide mb-1.5">Environment</p>
            <div class="space-y-1.5">
              <label class="flex items-center justify-between gap-2 text-sm cursor-pointer">
                <span class="flex items-center gap-1.5">
                  <input
                    type="checkbox"
                    name="env_ids[]"
                    value="none"
                    checked={"none" in @filter_env_ids}
                    class="rounded border-zinc-300"
                  />
                  <span class="italic text-zinc-400">None</span>
                </span>
                <span class="text-xs text-zinc-400">{Map.get(@facet_counts.env_ids, "none", 0)}</span>
              </label>
              <label :for={env <- @all_environments} class="flex items-center justify-between gap-2 text-sm cursor-pointer">
                <span class="flex items-center gap-1.5">
                  <input
                    type="checkbox"
                    name="env_ids[]"
                    value={env.id}
                    checked={env.id in @filter_env_ids}
                    class="rounded border-zinc-300"
                  />
                  {env.name}
                </span>
                <span class="text-xs text-zinc-400">{Map.get(@facet_counts.env_ids, env.id, 0)}</span>
              </label>
            </div>
          </div>

          <%!-- Capability facets --%>
          <div>
            <p class="text-xs font-semibold text-zinc-500 uppercase tracking-wide mb-1.5">Capabilities</p>
            <div class="space-y-1.5">
              <label class="flex items-center gap-1.5 text-sm cursor-pointer">
                <input
                  type="checkbox"
                  name="has_skills"
                  value="true"
                  checked={@filter_has_skills}
                  class="rounded border-zinc-300"
                />
                Has skills
              </label>
              <label class="flex items-center gap-1.5 text-sm cursor-pointer">
                <input
                  type="checkbox"
                  name="has_mcp"
                  value="true"
                  checked={@filter_has_mcp}
                  class="rounded border-zinc-300"
                />
                Has MCP servers
              </label>
            </div>
          </div>
        </form>

        <button
          :if={filters_active?(assigns)}
          phx-click="clear_filters"
          class="text-xs text-zinc-400 hover:text-zinc-700 underline underline-offset-2"
        >
          Clear all filters
        </button>
      </aside>

      <%!-- Main content --%>
      <div class="flex-1 min-w-0 space-y-4">
        <div class="flex items-center justify-between">
          <h1 class="text-2xl font-semibold">Agents</h1>
          <.link navigate={~p"/agents/new"}><.btn>+ New agent</.btn></.link>
        </div>

        <div
          :if={@agents == [] and not filters_active?(assigns)}
          class="rounded border border-dashed border-zinc-300 p-8 text-center text-zinc-500"
        >
          No agents yet.
        </div>

        <div
          :if={@agents == [] and filters_active?(assigns)}
          class="rounded border border-dashed border-zinc-300 p-8 text-center text-zinc-500"
        >
          No agents match the current filters.
        </div>

        <table :if={@agents != []} class="w-full text-sm bg-white rounded shadow border border-zinc-200">
          <thead class="text-left text-zinc-500 border-b border-zinc-200">
            <tr>
              <th class="px-4 py-2">Name</th>
              <th class="px-4 py-2">Runtime</th>
              <th class="px-4 py-2">Model</th>
              <th class="px-4 py-2">Env</th>
              <th class="px-4 py-2"></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={a <- @agents} class="border-b border-zinc-100 last:border-0 hover:bg-zinc-50">
              <td class="px-4 py-2 font-medium">{a.name}</td>
              <td class="px-4 py-2 text-zinc-600">{a.runtime}</td>
              <td class="px-4 py-2 text-zinc-600 font-mono text-xs">{a.model}</td>
              <td class="px-4 py-2 text-zinc-600">{env_name(a.environment)}</td>
              <td class="px-4 py-2 text-right space-x-2">
                <.link navigate={~p"/agents/#{a.id}/edit"}><.btn_secondary>Edit</.btn_secondary></.link>
                <.btn_danger phx-click="delete" phx-value-id={a.id} data-confirm="Delete agent?">Delete</.btn_danger>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  defp env_name(nil), do: "—"
  defp env_name(env), do: env.name

  defp compute_facets(agents) do
    runtimes = Enum.frequencies_by(agents, & &1.runtime)

    env_ids =
      Enum.frequencies_by(agents, fn a ->
        if a.environment_id, do: a.environment_id, else: "none"
      end)

    %{runtimes: runtimes, env_ids: env_ids}
  end

  defp extract_environments(agents) do
    agents
    |> Enum.map(& &1.environment)
    |> Enum.filter(& &1)
    |> Enum.uniq_by(& &1.id)
    |> Enum.sort_by(& &1.name)
  end

  defp current_filters(assigns) do
    [
      search: assigns.filter_search,
      runtimes: assigns.filter_runtimes,
      env_ids: assigns.filter_env_ids,
      has_skills: assigns.filter_has_skills,
      has_mcp: assigns.filter_has_mcp
    ]
  end

  defp filters_active?(assigns) do
    assigns.filter_search != "" or
      assigns.filter_runtimes != [] or
      assigns.filter_env_ids != [] or
      assigns.filter_has_skills or
      assigns.filter_has_mcp
  end
end
```

- [ ] **Step 2: Verify the LiveView compiles without errors**

```bash
cd apps/agent_on_demand && mix compile --warnings-as-errors
```

Expected: clean compile, no warnings.

- [ ] **Step 3: Run the full test suite**

```bash
mix test
```

Expected: all tests pass (no regressions from existing tests).

- [ ] **Step 4: Smoke-test in a browser**

```bash
mix phx.server
```

Navigate to `http://localhost:4000/agents`. Verify:
- Left sidebar shows Runtime and Environment facets with counts
- Checking a runtime checkbox immediately narrows the table
- Search input filters by name with a short debounce delay
- "Has skills" and "Has MCP servers" checkboxes filter correctly
- "Clear all filters" link appears when any filter is active and resets all filters
- Deleting an agent refreshes both the table and facet counts
- The "No agents match the current filters" message appears when filters yield zero results

- [ ] **Step 5: Commit**

```bash
git add apps/agent_on_demand/lib/agent_on_demand_web/live/agents_live/index.ex
git commit -m "feat: add faceted filter sidepanel to agents list page"
```
