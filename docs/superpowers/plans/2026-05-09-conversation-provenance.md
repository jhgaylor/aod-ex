# Conversation Provenance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Track what initiated each conversation (`"ui"`, `"api"`, or `"agent"`) and which conversation spawned it, so the full parent→child chain can be reconstructed.

**Architecture:** Two new columns on `conversations` (`source` string, `parent_conversation_id` UUID FK). Populated at creation: LiveView injects `source: "ui"`; the API controller reads `X-AoD-Parent-Conversation-Id` header to set `"agent"` vs `"api"`. ConversationServer injects `AOD_CONVERSATION_ID` as an env var into every sprite; SKILL.md is updated to pass it as a header on all spawn calls.

**Tech Stack:** Elixir, Ecto (SQLite), Phoenix LiveView, Phoenix JSON views

---

## File Map

| File | Change |
|------|--------|
| `apps/agent_on_demand/priv/repo/migrations/20260509000000_add_provenance_to_conversations.exs` | **Create** — migration |
| `apps/agent_on_demand/lib/agent_on_demand/conversations/conversation.ex` | **Modify** — add fields, associations, validation |
| `apps/agent_on_demand/lib/agent_on_demand/conversations.ex` | **Modify** — thread provenance through `start_conversation/1` |
| `apps/agent_on_demand/lib/agent_on_demand/conversations/conversation_server.ex` | **Modify** — inject `AOD_CONVERSATION_ID` env var |
| `apps/agent_on_demand/lib/agent_on_demand_web/controllers/conversation_controller.ex` | **Modify** — read header, derive source |
| `apps/agent_on_demand/lib/agent_on_demand_web/controllers/conversation_json.ex` | **Modify** — expose provenance fields |
| `apps/agent_on_demand/priv/sprite_skills/aod/SKILL.md` | **Modify** — add header to curl examples |
| `apps/agent_on_demand/lib/agent_on_demand_web/live/conversations_live/new.ex` | **Modify** — pass `source: "ui"` |
| `apps/agent_on_demand/lib/agent_on_demand_web/live/conversations_live/index.ex` | **Modify** — source badge in table |
| `apps/agent_on_demand/lib/agent_on_demand_web/live/conversations_live/show.ex` | **Modify** — provenance panel |

---

## Task 1: Migration

**Files:**
- Create: `apps/agent_on_demand/priv/repo/migrations/20260509000000_add_provenance_to_conversations.exs`

- [ ] **Step 1: Create the migration file**

```elixir
defmodule AgentOnDemand.Repo.Migrations.AddProvenanceToConversations do
  use Ecto.Migration

  def change do
    alter table(:conversations) do
      add :source, :string, null: false, default: "api"
      add :parent_conversation_id, :binary_id, null: true
    end

    create index(:conversations, [:parent_conversation_id])
  end
end
```

- [ ] **Step 2: Run the migration**

```bash
cd apps/agent_on_demand && mix ecto.migrate
```

Expected: `[info]  == Running 20260509000000 AgentOnDemand.Repo.Migrations.AddProvenanceToConversations.change/0 forward`

- [ ] **Step 3: Commit**

```bash
git add apps/agent_on_demand/priv/repo/migrations/20260509000000_add_provenance_to_conversations.exs
git commit -m "feat: add provenance migration to conversations table"
```

---

## Task 2: Conversation Schema

**Files:**
- Modify: `apps/agent_on_demand/lib/agent_on_demand/conversations/conversation.ex`

- [ ] **Step 1: Write the failing test**

Create `apps/agent_on_demand/test/agent_on_demand/conversations/conversation_test.exs`:

```elixir
defmodule AgentOnDemand.Conversations.ConversationTest do
  use AgentOnDemand.DataCase

  alias AgentOnDemand.Conversations.Conversation

  # Minimal attrs that pass all existing validations.
  # sandbox_id uses a random UUID — FK constraint is not checked in changeset unit tests.
  defp base_attrs do
    %{
      runtime: "claude",
      status: "pending",
      sandbox_id: Ecto.UUID.generate()
    }
  end

  describe "source field" do
    test "defaults to api" do
      changeset = Conversation.changeset(%Conversation{}, base_attrs())
      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :source) == "api"
    end

    test "accepts ui" do
      changeset = Conversation.changeset(%Conversation{}, Map.put(base_attrs(), :source, "ui"))
      assert changeset.valid?
    end

    test "accepts agent" do
      changeset = Conversation.changeset(%Conversation{}, Map.put(base_attrs(), :source, "agent"))
      assert changeset.valid?
    end

    test "rejects unknown values" do
      changeset = Conversation.changeset(%Conversation{}, Map.put(base_attrs(), :source, "cli"))
      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).source
    end
  end

  describe "parent_conversation_id field" do
    test "accepts nil" do
      changeset = Conversation.changeset(%Conversation{}, base_attrs())
      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :parent_conversation_id) == nil
    end

    test "accepts a valid UUID" do
      parent_id = Ecto.UUID.generate()
      attrs = Map.put(base_attrs(), :parent_conversation_id, parent_id)
      changeset = Conversation.changeset(%Conversation{}, attrs)
      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :parent_conversation_id) == parent_id
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd apps/agent_on_demand && mix test test/agent_on_demand/conversations/conversation_test.exs
```

Expected: multiple failures — field does not exist yet.

- [ ] **Step 3: Update the Conversation schema**

Replace `apps/agent_on_demand/lib/agent_on_demand/conversations/conversation.ex` with:

```elixir
defmodule AgentOnDemand.Conversations.Conversation do
  use Ecto.Schema
  import Ecto.Changeset

  alias AgentOnDemand.Agents.Agent
  alias AgentOnDemand.Conversations.{Sandbox, Turn}
  alias AgentOnDemand.Vaults.Vault

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(pending running idle completed failed terminated)
  @sources ~w(ui api agent)

  schema "conversations" do
    field :runtime, :string
    field :status, :string, default: "pending"
    field :runtime_session_id, :string
    field :source, :string, default: "api"
    field :parent_conversation_id, :binary_id
    belongs_to :sandbox, Sandbox
    belongs_to :agent, Agent
    belongs_to :vault, Vault
    belongs_to :parent_conversation, __MODULE__,
      foreign_key: :parent_conversation_id,
      references: :id,
      type: :binary_id,
      define_field: false
    has_many :child_conversations, __MODULE__, foreign_key: :parent_conversation_id
    has_many :turns, Turn
    timestamps(type: :utc_datetime)
  end

  def statuses, do: @statuses
  def sources, do: @sources

  def changeset(conv, attrs) do
    conv
    |> cast(attrs, [
      :runtime,
      :status,
      :runtime_session_id,
      :source,
      :parent_conversation_id,
      :sandbox_id,
      :agent_id,
      :vault_id
    ])
    |> validate_required([:runtime, :status, :sandbox_id])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:source, @sources)
    |> foreign_key_constraint(:sandbox_id)
    |> foreign_key_constraint(:agent_id)
    |> foreign_key_constraint(:vault_id)
    |> foreign_key_constraint(:parent_conversation_id)
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd apps/agent_on_demand && mix test test/agent_on_demand/conversations/conversation_test.exs
```

Expected: all green.

- [ ] **Step 5: Commit**

```bash
git add apps/agent_on_demand/lib/agent_on_demand/conversations/conversation.ex \
        apps/agent_on_demand/test/agent_on_demand/conversations/conversation_test.exs
git commit -m "feat: add source and parent_conversation_id to Conversation schema"
```

---

## Task 3: Thread Provenance Through `start_conversation`

**Files:**
- Modify: `apps/agent_on_demand/lib/agent_on_demand/conversations.ex`

- [ ] **Step 1: Write the failing test**

Add to `apps/agent_on_demand/test/agent_on_demand/conversations_test.exs` (create the file if it doesn't exist, or append to the existing describe block for `start_conversation`):

```elixir
# In the start_conversation describe block (add alongside existing tests):

test "defaults source to api when not provided", %{agent: agent} do
  {:ok, conv} = Conversations.start_conversation(%{"agent_id" => agent.id, "prompt" => "hi"})
  assert conv.source == "api"
  assert conv.parent_conversation_id == nil
end

test "stores source ui when provided", %{agent: agent} do
  {:ok, conv} = Conversations.start_conversation(%{
    "agent_id" => agent.id,
    "prompt" => "hi",
    "source" => "ui"
  })
  assert conv.source == "ui"
end

test "stores parent_conversation_id when provided", %{agent: agent} do
  {:ok, parent} = Conversations.start_conversation(%{"agent_id" => agent.id})
  {:ok, child} = Conversations.start_conversation(%{
    "agent_id" => agent.id,
    "source" => "agent",
    "parent_conversation_id" => parent.id
  })
  assert child.source == "agent"
  assert child.parent_conversation_id == parent.id
end
```

- [ ] **Step 2: Run the failing tests**

```bash
cd apps/agent_on_demand && mix test test/agent_on_demand/conversations_test.exs --only start_conversation
```

Expected: failures — `source` is not threaded through yet.

- [ ] **Step 3: Update `start_conversation` in `conversations.ex`**

Find the `create_conversation` call inside `start_conversation/1` (around line 130 in the original). Change:

```elixir
{:ok, conv} <-
  create_conversation(%{
    sandbox_id: sandbox.id,
    agent_id: agent.id,
    vault_id: vault_id,
    runtime: agent.runtime,
    status: "pending"
  }) do
```

To:

```elixir
{:ok, conv} <-
  create_conversation(%{
    sandbox_id: sandbox.id,
    agent_id: agent.id,
    vault_id: vault_id,
    runtime: agent.runtime,
    status: "pending",
    source: attrs["source"] || "api",
    parent_conversation_id: attrs["parent_conversation_id"]
  }) do
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd apps/agent_on_demand && mix test test/agent_on_demand/conversations_test.exs
```

Expected: green.

- [ ] **Step 5: Commit**

```bash
git add apps/agent_on_demand/lib/agent_on_demand/conversations.ex \
        apps/agent_on_demand/test/agent_on_demand/conversations_test.exs
git commit -m "feat: thread source and parent_conversation_id through start_conversation"
```

---

## Task 4: Inject `AOD_CONVERSATION_ID` in ConversationServer

**Files:**
- Modify: `apps/agent_on_demand/lib/agent_on_demand/conversations/conversation_server.ex`

- [ ] **Step 1: Add `conversation_env/1` helper and update `build_sprite_env/4` → `build_sprite_env/5`**

Find `build_sprite_env/4` in `conversation_server.ex`:

```elixir
defp build_sprite_env(runtime_module, agent, env, secrets) do
  (runtime_module.default_env(agent) || []) ++
    aod_callback_env() ++
    otel_propagation_env() ++
    git_author_env() ++
    if(env,
      do: Enum.map(env.env_vars, fn {k, v} -> {to_string(k), to_string(v)} end),
      else: []
    ) ++
    Enum.map(secrets, fn {k, v} -> {k, v} end)
end
```

Replace with:

```elixir
defp build_sprite_env(runtime_module, agent, env, secrets, conversation_id) do
  (runtime_module.default_env(agent) || []) ++
    aod_callback_env() ++
    conversation_env(conversation_id) ++
    otel_propagation_env() ++
    git_author_env() ++
    if(env,
      do: Enum.map(env.env_vars, fn {k, v} -> {to_string(k), to_string(v)} end),
      else: []
    ) ++
    Enum.map(secrets, fn {k, v} -> {k, v} end)
end

defp conversation_env(nil), do: []
defp conversation_env(conv_id) when is_binary(conv_id), do: [{"AOD_CONVERSATION_ID", conv_id}]
```

- [ ] **Step 2: Update both call sites of `build_sprite_env`**

In `do_fresh_provision_inner`, find:

```elixir
sprite_env = build_sprite_env(state.runtime_module, agent, env, secrets)
```

Change to:

```elixir
sprite_env = build_sprite_env(state.runtime_module, agent, env, secrets, state.conversation_id)
```

In `do_reattach`, find:

```elixir
sprite_env = build_sprite_env(state.runtime_module, agent, env, secrets)
```

Change to:

```elixir
sprite_env = build_sprite_env(state.runtime_module, agent, env, secrets, state.conversation_id)
```

- [ ] **Step 3: Verify the app compiles cleanly**

```bash
cd apps/agent_on_demand && mix compile --warnings-as-errors
```

Expected: no errors.

- [ ] **Step 4: Commit**

```bash
git add apps/agent_on_demand/lib/agent_on_demand/conversations/conversation_server.ex
git commit -m "feat: inject AOD_CONVERSATION_ID env var into every sprite"
```

---

## Task 5: Read Header in ConversationController

**Files:**
- Modify: `apps/agent_on_demand/lib/agent_on_demand_web/controllers/conversation_controller.ex`

- [ ] **Step 1: Write the failing test**

Add to `apps/agent_on_demand/test/agent_on_demand_web/controllers/conversation_controller_test.exs` (create if absent):

```elixir
defmodule AgentOnDemandWeb.ConversationControllerTest do
  use AgentOnDemandWeb.ConnCase

  # You'll need a valid agent fixture; adapt to whatever factory/fixture
  # pattern this project uses (look for existing controller tests for examples).

  describe "POST /api/conversations — provenance" do
    test "sets source to api when no parent header", %{conn: conn, agent: agent} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{admin_token()}")
        |> post("/api/conversations", %{agent_id: agent.id})

      assert %{"data" => %{"source" => "api", "parent_conversation_id" => nil}} =
               json_response(conn, 201)
    end

    test "sets source to agent and stores parent_id when header present", %{conn: conn, agent: agent} do
      parent_id = Ecto.UUID.generate()

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{admin_token()}")
        |> put_req_header("x-aod-parent-conversation-id", parent_id)
        |> post("/api/conversations", %{agent_id: agent.id})

      assert %{"data" => %{"source" => "agent", "parent_conversation_id" => ^parent_id}} =
               json_response(conn, 201)
    end
  end

  defp admin_token, do: Application.get_env(:agent_on_demand, :admin_token)
end
```

- [ ] **Step 2: Run to verify it fails**

```bash
cd apps/agent_on_demand && mix test test/agent_on_demand_web/controllers/conversation_controller_test.exs
```

Expected: failures — `source` not yet set from header.

- [ ] **Step 3: Update `create/2` in `conversation_controller.ex`**

Replace the current `create/2`:

```elixir
def create(conn, params) do
  images = decode_images(params["images"])
  params = Map.put(params, "images", images)

  with {:ok, conv} <- Conversations.start_conversation(params) do
    conn
    |> put_status(:created)
    |> render(:show, conversation: conv)
  end
end
```

With:

```elixir
def create(conn, params) do
  images = decode_images(params["images"])

  parent_id =
    conn
    |> get_req_header("x-aod-parent-conversation-id")
    |> List.first()

  {source, parent_id} =
    case parent_id do
      id when is_binary(id) and byte_size(id) > 0 -> {"agent", id}
      _ -> {"api", nil}
    end

  params =
    params
    |> Map.put("images", images)
    |> Map.put("source", source)
    |> Map.put("parent_conversation_id", parent_id)

  with {:ok, conv} <- Conversations.start_conversation(params) do
    conn
    |> put_status(:created)
    |> render(:show, conversation: conv)
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd apps/agent_on_demand && mix test test/agent_on_demand_web/controllers/conversation_controller_test.exs
```

Expected: green.

- [ ] **Step 5: Commit**

```bash
git add apps/agent_on_demand/lib/agent_on_demand_web/controllers/conversation_controller.ex \
        apps/agent_on_demand/test/agent_on_demand_web/controllers/conversation_controller_test.exs
git commit -m "feat: read X-AoD-Parent-Conversation-Id header in ConversationController"
```

---

## Task 6: Update SKILL.md — Propagate Header Automatically

**Files:**
- Modify: `apps/agent_on_demand/priv/sprite_skills/aod/SKILL.md`

- [ ] **Step 1: Add the header to Pattern A's inner spawn curl**

Find the xargs spawn block in Pattern A:

```bash
ids=$(printf '%s\n' "${prompts[@]}" | xargs -n1 -P8 -I{} sh -c '
  curl -s -X POST "$1/api/conversations" \
    -H "Authorization: Bearer $2" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg a "$3" --arg p "$4" "{agent_id:\$a, prompt:\$p}")" \
  | jq -r .data.id
' _ "$AOD_BASE_URL" "$AOD_TOKEN" "$AGENT_ID" {})
```

Replace with:

```bash
ids=$(printf '%s\n' "${prompts[@]}" | xargs -n1 -P8 -I{} sh -c '
  curl -s -X POST "$1/api/conversations" \
    -H "Authorization: Bearer $2" \
    -H "Content-Type: application/json" \
    -H "X-AoD-Parent-Conversation-Id: $AOD_CONVERSATION_ID" \
    -d "$(jq -n --arg a "$3" --arg p "$4" "{agent_id:\$a, prompt:\$p}")" \
  | jq -r .data.id
' _ "$AOD_BASE_URL" "$AOD_TOKEN" "$AGENT_ID" {})
```

- [ ] **Step 2: Add the header to Pattern B's spawn curl**

Find:

```bash
CONV=$(curl -s -X POST "$AOD_BASE_URL/api/conversations" \
  -H "Authorization: Bearer $AOD_TOKEN" -H "Content-Type: application/json" \
  -d "$(jq -n --arg a "$AGENT_ID" --arg p "$PROMPT" '{agent_id:$a, prompt:$p}')" \
  | jq -r .data.id)
```

Replace with:

```bash
CONV=$(curl -s -X POST "$AOD_BASE_URL/api/conversations" \
  -H "Authorization: Bearer $AOD_TOKEN" \
  -H "Content-Type: application/json" \
  -H "X-AoD-Parent-Conversation-Id: $AOD_CONVERSATION_ID" \
  -d "$(jq -n --arg a "$AGENT_ID" --arg p "$PROMPT" '{agent_id:$a, prompt:$p}')" \
  | jq -r .data.id)
```

- [ ] **Step 3: Add a provenance note to the "Important" section at the bottom**

In the `## Important` section, add this bullet after "Same `$AOD_TOKEN`...":

```markdown
- **Provenance is automatic.** `AOD_CONVERSATION_ID` is always present in your sprite's environment. Every `POST /api/conversations` call that includes `X-AoD-Parent-Conversation-Id: $AOD_CONVERSATION_ID` records this conversation as the parent, letting the operator reconstruct the full spawn chain.
```

- [ ] **Step 4: Commit**

```bash
git add apps/agent_on_demand/priv/sprite_skills/aod/SKILL.md
git commit -m "feat: propagate X-AoD-Parent-Conversation-Id header in aod skill"
```

---

## Task 7: LiveView new.ex — Pass `source: "ui"`

**Files:**
- Modify: `apps/agent_on_demand/lib/agent_on_demand_web/live/conversations_live/new.ex`

- [ ] **Step 1: Add `"source" => "ui"` before calling `start_conversation`**

Find `handle_event("submit", ...)`:

```elixir
def handle_event("submit", %{"conv" => params}, socket) do
  params = if params["vault_id"] == "", do: Map.delete(params, "vault_id"), else: params

  case Conversations.start_conversation(params) do
```

Change to:

```elixir
def handle_event("submit", %{"conv" => params}, socket) do
  params = if params["vault_id"] == "", do: Map.delete(params, "vault_id"), else: params
  params = Map.put(params, "source", "ui")

  case Conversations.start_conversation(params) do
```

- [ ] **Step 2: Verify compile**

```bash
cd apps/agent_on_demand && mix compile --warnings-as-errors
```

- [ ] **Step 3: Commit**

```bash
git add apps/agent_on_demand/lib/agent_on_demand_web/live/conversations_live/new.ex
git commit -m "feat: tag UI-created conversations with source=ui"
```

---

## Task 8: Expose Provenance in JSON View

**Files:**
- Modify: `apps/agent_on_demand/lib/agent_on_demand_web/controllers/conversation_json.ex`

- [ ] **Step 1: Add `source` and `parent_conversation_id` to `data/1`**

Find the `data/1` function:

```elixir
def data(%Conversation{} = c) do
  %{
    id: c.id,
    sandbox_id: c.sandbox_id,
    sandbox: sandbox_data(c.sandbox),
    agent_id: c.agent_id,
    vault_id: c.vault_id,
    runtime: c.runtime,
    status: c.status,
    runtime_session_id: c.runtime_session_id,
    inserted_at: c.inserted_at,
    updated_at: c.updated_at
  }
end
```

Replace with:

```elixir
def data(%Conversation{} = c) do
  %{
    id: c.id,
    sandbox_id: c.sandbox_id,
    sandbox: sandbox_data(c.sandbox),
    agent_id: c.agent_id,
    vault_id: c.vault_id,
    runtime: c.runtime,
    status: c.status,
    runtime_session_id: c.runtime_session_id,
    source: c.source,
    parent_conversation_id: c.parent_conversation_id,
    inserted_at: c.inserted_at,
    updated_at: c.updated_at
  }
end
```

- [ ] **Step 2: Run the full test suite to confirm nothing regressed**

```bash
cd apps/agent_on_demand && mix test
```

Expected: green.

- [ ] **Step 3: Commit**

```bash
git add apps/agent_on_demand/lib/agent_on_demand_web/controllers/conversation_json.ex
git commit -m "feat: expose source and parent_conversation_id in conversation JSON"
```

---

## Task 9: Conversation List — Source Badge

**Files:**
- Modify: `apps/agent_on_demand/lib/agent_on_demand_web/live/conversations_live/index.ex`

- [ ] **Step 1: Add a Source column header**

In the `<thead>` section of the table, find the row with `Status`, `Task`, `Agent`, `Runtime`, `Started`, `Last active`, and the actions column. Add a new `<th>` for Source after `Runtime`:

```html
<th class="w-16 px-3 py-1.5 font-medium">Source</th>
```

So the header row becomes (showing just the new addition in context):

```heex
<th class="w-20 px-3 py-1.5 font-medium">Runtime</th>
<th class="w-16 px-3 py-1.5 font-medium">Source</th>
<th
  class={["w-24 px-3 py-1.5 font-medium cursor-pointer ...
```

- [ ] **Step 2: Add a source cell to each table row**

In the `<tr :for={c <- @conversations}>` block, find the runtime cell:

```heex
<td class="px-3 py-2 text-zinc-600 truncate">{c.runtime}</td>
```

Add the source cell immediately after it:

```heex
<td class="px-3 py-2">
  <.source_badge source={c.source} />
</td>
```

- [ ] **Step 3: Add the `source_badge` component**

Add this private component function at the bottom of the module, before the last `end`:

```elixir
attr :source, :string, default: "api"

defp source_badge(%{source: "ui"} = assigns) do
  ~H"""
  <span class="inline-flex items-center rounded px-1.5 py-0.5 text-[10px] font-medium bg-blue-50 text-blue-700 border border-blue-200">
    UI
  </span>
  """
end

defp source_badge(%{source: "agent"} = assigns) do
  ~H"""
  <span class="inline-flex items-center rounded px-1.5 py-0.5 text-[10px] font-medium bg-amber-50 text-amber-700 border border-amber-200">
    Agent
  </span>
  """
end

defp source_badge(assigns) do
  ~H"""
  <span class="inline-flex items-center rounded px-1.5 py-0.5 text-[10px] font-medium bg-zinc-100 text-zinc-500 border border-zinc-200">
    API
  </span>
  """
end
```

- [ ] **Step 4: Verify compile**

```bash
cd apps/agent_on_demand && mix compile --warnings-as-errors
```

- [ ] **Step 5: Commit**

```bash
git add apps/agent_on_demand/lib/agent_on_demand_web/live/conversations_live/index.ex
git commit -m "feat: show source badge in conversation list"
```

---

## Task 10: Conversation Detail — Provenance Panel

**Files:**
- Modify: `apps/agent_on_demand/lib/agent_on_demand_web/live/conversations_live/show.ex`

- [ ] **Step 1: Add provenance rows to the detail header**

In `render/1`, find the block showing the conversation's runtime, sandbox, and vault info:

```heex
<div class="text-sm text-zinc-500">runtime: {@conv.runtime}</div>
<div :if={@conv.sandbox} class="text-sm text-zinc-500 font-mono">
  sprite: ...
</div>
<div :if={@conv.vault} class="text-sm text-zinc-500">
  vault: ...
</div>
```

Add provenance info immediately after the vault line:

```heex
<div class="text-sm text-zinc-500 flex items-center gap-1.5">
  source: <.source_badge source={@conv.source} />
</div>
<div :if={@conv.parent_conversation_id} class="text-sm text-zinc-500">
  spawned by:
  <.link
    navigate={~p"/conversations/#{@conv.parent_conversation_id}"}
    class="font-mono underline text-zinc-700 hover:text-zinc-900"
  >
    {String.slice(@conv.parent_conversation_id, 0, 8)}
  </.link>
</div>
```

- [ ] **Step 2: Add the `source_badge` component to show.ex**

Add the same `source_badge` component from Task 9 at the bottom of this module as well (before the last `end`):

```elixir
attr :source, :string, default: "api"

defp source_badge(%{source: "ui"} = assigns) do
  ~H"""
  <span class="inline-flex items-center rounded px-1.5 py-0.5 text-[10px] font-medium bg-blue-50 text-blue-700 border border-blue-200">
    UI
  </span>
  """
end

defp source_badge(%{source: "agent"} = assigns) do
  ~H"""
  <span class="inline-flex items-center rounded px-1.5 py-0.5 text-[10px] font-medium bg-amber-50 text-amber-700 border border-amber-200">
    Agent
  </span>
  """
end

defp source_badge(assigns) do
  ~H"""
  <span class="inline-flex items-center rounded px-1.5 py-0.5 text-[10px] font-medium bg-zinc-100 text-zinc-500 border border-zinc-200">
    API
  </span>
  """
end
```

- [ ] **Step 3: Verify compile**

```bash
cd apps/agent_on_demand && mix compile --warnings-as-errors
```

- [ ] **Step 4: Run full test suite**

```bash
cd apps/agent_on_demand && mix test
```

Expected: green.

- [ ] **Step 5: Commit**

```bash
git add apps/agent_on_demand/lib/agent_on_demand_web/live/conversations_live/show.ex
git commit -m "feat: show provenance (source badge + parent link) on conversation detail"
```

---

## Final Verification

- [ ] **Run the full test suite one last time**

```bash
cd apps/agent_on_demand && mix test
```

Expected: all green.

- [ ] **Check for unused warnings**

```bash
cd apps/agent_on_demand && mix compile --warnings-as-errors
```

Expected: no warnings.
