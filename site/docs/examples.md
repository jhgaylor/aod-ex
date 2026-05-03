# Examples

Concrete patterns. Each example shows the same logic in all four [SDKs](sdks/python.md) plus a shell fallback. Pick the tab for your language — your choice persists across the rest of the site.

All examples assume `AOD_BASE_URL` and `AOD_TOKEN` are set in the environment — every SDK falls back to those.

---

## 1. Send a prompt, get the answer back

The simplest possible thing.

=== "Python"

    ```python
    from aod_client import Client

    with Client() as aod:
        agent = next(a for a in aod.agents.list() if a["name"] == "hello")
        conv  = aod.conversations.create(agent_id=agent["id"], prompt="Say hi.")
        print(aod.conversations.wait_for_result(conv["id"]))
    ```

=== "TypeScript"

    ```ts
    import { Client } from "@aod/client";

    const aod   = new Client({ token: process.env.AOD_TOKEN! });
    const agent = (await aod.agents.list()).find(a => a.name === "hello")!;
    const conv  = await aod.conversations.create({ agent_id: agent.id, prompt: "Say hi." });
    console.log(await aod.conversations.waitForResult(conv.id));
    ```

=== "Go"

    ```go
    ctx := context.Background()
    c, _ := aod.New(aod.Config{Token: os.Getenv("AOD_TOKEN")})

    agents, _ := c.Agents.List(ctx)
    var agent aod.Agent
    for _, a := range agents {
        if a.Name == "hello" { agent = a; break }
    }

    conv, _ := c.Conversations.Create(ctx, aod.ConversationCreate{
        AgentID: agent.ID, Prompt: "Say hi.",
    })
    result, _ := c.Conversations.WaitForResult(ctx, conv.ID)
    fmt.Println(result)
    ```

=== "Elixir"

    ```elixir
    client = AodClient.new()

    {:ok, agents} = AodClient.Agents.list(client)
    agent = Enum.find(agents, & &1["name"] == "hello")

    {:ok, conv} = AodClient.Conversations.create(client,
                    agent_id: agent["id"], prompt: "Say hi.")
    {:ok, text} = AodClient.Conversations.wait_for_result(client, conv["id"])
    IO.puts(text)
    ```

=== "shell"

    ```bash
    AGENT_ID=$(curl -s "$AOD_BASE_URL/api/agents" \
      -H "Authorization: Bearer $AOD_TOKEN" \
      | jq -r '.data[] | select(.name=="hello") | .id')

    CONV=$(curl -s -X POST "$AOD_BASE_URL/api/conversations" \
      -H "Authorization: Bearer $AOD_TOKEN" -H "Content-Type: application/json" \
      -d "{\"agent_id\":\"$AGENT_ID\",\"prompt\":\"Say hi.\"}" \
      | jq -r .data.id)

    while [[ $(curl -s "$AOD_BASE_URL/api/conversations/$CONV" \
      -H "Authorization: Bearer $AOD_TOKEN" | jq -r .data.status) =~ ^(running|pending)$ ]]; do
      sleep 2
    done

    curl -sN --max-time 5 \
      "$AOD_BASE_URL/api/conversations/$CONV/stream?streams=stdout&wait=false" \
      -H "Authorization: Bearer $AOD_TOKEN" \
    | awk '/^data: /{sub(/^data: /,""); print}' \
    | jq -r '.data | fromjson? | select(.type=="result") | .result' \
    | tail -n1
    ```

---

## 2. Fan out N agents in parallel

Spawn one conversation per item, wait for them in parallel, gather their answers.

=== "Python"

    ```python
    from concurrent.futures import ThreadPoolExecutor
    from aod_client import Client

    AGENT_ID = "..."
    prompts  = ["Audit api", "Audit worker", "Audit scheduler"]

    with Client() as aod, ThreadPoolExecutor(max_workers=8) as pool:
        # spawn in parallel
        convs = list(pool.map(
            lambda p: aod.conversations.create(agent_id=AGENT_ID, prompt=p),
            prompts,
        ))
        # wait + gather in parallel
        results = list(pool.map(
            lambda c: aod.conversations.wait_for_result(c["id"]),
            convs,
        ))
        for prompt, result in zip(prompts, results):
            print(f"=== {prompt} ===\n{result}\n")
    ```

=== "TypeScript"

    ```ts
    import { Client } from "@aod/client";

    const AGENT_ID = "...";
    const prompts  = ["Audit api", "Audit worker", "Audit scheduler"];

    const aod = new Client({ token: process.env.AOD_TOKEN! });

    const convs = await Promise.all(
      prompts.map(p => aod.conversations.create({ agent_id: AGENT_ID, prompt: p }))
    );

    const results = await Promise.all(
      convs.map(c => aod.conversations.waitForResult(c.id))
    );

    prompts.forEach((p, i) => console.log(`=== ${p} ===\n${results[i]}\n`));
    ```

=== "Go"

    ```go
    ctx := context.Background()
    c, _ := aod.New(aod.Config{Token: os.Getenv("AOD_TOKEN")})

    agentID := "..."
    prompts := []string{"Audit api", "Audit worker", "Audit scheduler"}

    type out struct{ idx int; text string }
    results := make([]string, len(prompts))

    var wg sync.WaitGroup
    ch := make(chan out, len(prompts))
    for i, p := range prompts {
        wg.Add(1)
        go func(i int, p string) {
            defer wg.Done()
            conv, _ := c.Conversations.Create(ctx, aod.ConversationCreate{AgentID: agentID, Prompt: p})
            text, _ := c.Conversations.WaitForResult(ctx, conv.ID)
            ch <- out{i, text}
        }(i, p)
    }
    wg.Wait(); close(ch)
    for r := range ch { results[r.idx] = r.text }

    for i, p := range prompts {
        fmt.Printf("=== %s ===\n%s\n\n", p, results[i])
    }
    ```

=== "Elixir"

    ```elixir
    client    = AodClient.new()
    agent_id  = "..."
    prompts   = ["Audit api", "Audit worker", "Audit scheduler"]

    prompts
    |> Task.async_stream(
      fn p ->
        {:ok, conv} = AodClient.Conversations.create(client, agent_id: agent_id, prompt: p)
        {:ok, text} = AodClient.Conversations.wait_for_result(client, conv["id"])
        {p, text}
      end,
      max_concurrency: 8,
      timeout: :infinity
    )
    |> Enum.each(fn {:ok, {p, text}} ->
      IO.puts("=== #{p} ===\n#{text}\n")
    end)
    ```

=== "shell"

    ```bash
    AGENT_ID=...

    prompts=("Audit api"
             "Audit worker"
             "Audit scheduler")

    ids=$(printf '%s\n' "${prompts[@]}" | xargs -n1 -P8 -I{} sh -c '
      curl -s -X POST "$1/api/conversations" \
        -H "Authorization: Bearer $2" -H "Content-Type: application/json" \
        -d "$(jq -n --arg a "$3" --arg p "$4" "{agent_id:\$a, prompt:\$p}")" \
      | jq -r .data.id
    ' _ "$AOD_BASE_URL" "$AOD_TOKEN" "$AGENT_ID" {})

    echo "$ids" | xargs -n1 -P10 -I{} sh -c '
      while :; do
        s=$(curl -s "$1/api/conversations/$3" -H "Authorization: Bearer $2" | jq -r .data.status)
        case "$s" in running|pending) sleep 2 ;; *) break ;; esac
      done
    ' _ "$AOD_BASE_URL" "$AOD_TOKEN" {}

    while IFS= read -r conv; do
      echo "=== $conv ==="
      curl -sN --max-time 5 \
        "$AOD_BASE_URL/api/conversations/$conv/stream?streams=stdout&wait=false" \
        -H "Authorization: Bearer $AOD_TOKEN" \
      | awk '/^data: /{sub(/^data: /,""); print}' \
      | jq -r '.data | fromjson? | select(.type=="result") | .result' \
      | tail -n1
    done <<<"$ids"
    ```

---

## 3. Multi-turn conversation (resume context)

After turn 1, send a follow-up. The runtime CLI's session resumes — agent remembers turn 1.

=== "Python"

    ```python
    aod.conversations.prompt(conv["id"], "Now compare that to the worker service.")
    print(aod.conversations.wait_for_result(conv["id"]))
    ```

=== "TypeScript"

    ```ts
    await aod.conversations.prompt(conv.id, "Now compare that to the worker service.");
    console.log(await aod.conversations.waitForResult(conv.id));
    ```

=== "Go"

    ```go
    _, _ = c.Conversations.Prompt(ctx, conv.ID, "Now compare that to the worker service.")
    text, _ := c.Conversations.WaitForResult(ctx, conv.ID)
    fmt.Println(text)
    ```

=== "Elixir"

    ```elixir
    AodClient.Conversations.prompt(client, conv["id"], "Now compare that to the worker service.")
    {:ok, text} = AodClient.Conversations.wait_for_result(client, conv["id"])
    IO.puts(text)
    ```

=== "shell"

    ```bash
    curl -s -X POST "$AOD_BASE_URL/api/conversations/$CONV/prompts" \
      -H "Authorization: Bearer $AOD_TOKEN" -H "Content-Type: application/json" \
      -d '{"prompt":"Now compare that to the worker service."}'

    # Then poll status / drain replay the same way as turn 1.
    ```

---

## 4. Compare runtimes on the same task

Same prompt, two agents — one Claude, one Codex. See which gets it right.

=== "Python"

    ```python
    PROMPT = "Refactor src/auth.py to use dependency injection."

    with Client() as aod:
        agents = {a["name"]: a for a in aod.agents.list()}
        for name in ["claude-coder", "codex-coder"]:
            conv   = aod.conversations.create(agent_id=agents[name]["id"], prompt=PROMPT)
            answer = aod.conversations.wait_for_result(conv["id"])
            print(f"=== {name} ===\n{answer}\n")
    ```

=== "TypeScript"

    ```ts
    const PROMPT = "Refactor src/auth.py to use dependency injection.";

    const agents = await aod.agents.list();
    const byName = new Map(agents.map(a => [a.name, a]));

    for (const name of ["claude-coder", "codex-coder"]) {
      const agent = byName.get(name)!;
      const conv  = await aod.conversations.create({ agent_id: agent.id, prompt: PROMPT });
      const text  = await aod.conversations.waitForResult(conv.id);
      console.log(`=== ${name} ===\n${text}\n`);
    }
    ```

=== "Go"

    ```go
    prompt := "Refactor src/auth.py to use dependency injection."

    agents, _ := c.Agents.List(ctx)
    byName := map[string]aod.Agent{}
    for _, a := range agents { byName[a.Name] = a }

    for _, name := range []string{"claude-coder", "codex-coder"} {
        a := byName[name]
        conv, _ := c.Conversations.Create(ctx, aod.ConversationCreate{
            AgentID: a.ID, Prompt: prompt,
        })
        text, _ := c.Conversations.WaitForResult(ctx, conv.ID)
        fmt.Printf("=== %s ===\n%s\n\n", name, text)
    }
    ```

=== "Elixir"

    ```elixir
    prompt = "Refactor src/auth.py to use dependency injection."

    {:ok, agents} = AodClient.Agents.list(client)
    by_name = Map.new(agents, &{&1["name"], &1})

    for name <- ["claude-coder", "codex-coder"] do
      agent = by_name[name]
      {:ok, conv} = AodClient.Conversations.create(client, agent_id: agent["id"], prompt: prompt)
      {:ok, text} = AodClient.Conversations.wait_for_result(client, conv["id"])
      IO.puts("=== #{name} ===\n#{text}\n")
    end
    ```

=== "shell"

    ```bash
    PROMPT="Refactor src/auth.py to use dependency injection."
    CLAUDE_AGENT=...
    CODEX_AGENT=...

    for AGENT in "$CLAUDE_AGENT" "$CODEX_AGENT"; do
      conv=$(curl -s -X POST "$AOD_BASE_URL/api/conversations" \
        -H "Authorization: Bearer $AOD_TOKEN" -H "Content-Type: application/json" \
        -d "$(jq -n --arg a "$AGENT" --arg p "$PROMPT" '{agent_id:$a, prompt:$p}')" \
        | jq -r .data.id)
      echo "$AGENT → $conv"
      # gather as in example 1
    done
    ```

---

## 5. Watch progress in real time

Skip polling — stream events live and react as they arrive.

=== "Python"

    ```python
    from aod_client import Client

    with Client() as aod:
        conv = aod.conversations.create(agent_id="...", prompt="Build the website.")
        for ev in aod.conversations.stream(conv["id"]):
            if ev.kind == "stage":
                print(f"[stage] {ev.stage} · {ev.state}")
            elif isinstance(ev.data, dict):
                t = ev.data.get("type")
                if t == "result":
                    print("\nDONE:", ev.data.get("result", ""))
                    break
    ```

=== "TypeScript"

    ```ts
    const conv = await aod.conversations.create({ agent_id: "...", prompt: "Build the website." });

    for await (const ev of aod.conversations.stream(conv.id)) {
      if (ev.kind === "stage") {
        console.log(`[stage] ${ev.stage} · ${ev.state}`);
      } else if (ev.data && typeof ev.data === "object") {
        const d: any = ev.data;
        if (d.type === "result") {
          console.log("\nDONE:", d.result);
          break;
        }
      }
    }
    ```

=== "Go"

    ```go
    ctx, cancel := context.WithCancel(context.Background())
    defer cancel()

    conv, _ := c.Conversations.Create(ctx, aod.ConversationCreate{AgentID: "...", Prompt: "Build the website."})
    ch, _  := c.Conversations.Stream(ctx, conv.ID, aod.StreamOpts{})

    for ev := range ch {
        if ev.Kind == "stage" {
            fmt.Printf("[stage] %s · %s\n", ev.Stage, ev.State)
        } else if d, ok := ev.Data.(map[string]any); ok {
            if d["type"] == "result" {
                fmt.Println("\nDONE:", d["result"])
                cancel()
            }
        }
    }
    ```

=== "Elixir"

    ```elixir
    {:ok, conv} = AodClient.Conversations.create(client, agent_id: "...", prompt: "Build the website.")

    client
    |> AodClient.Conversations.stream(conv["id"])
    |> Enum.reduce_while(nil, fn ev, _ ->
      case ev do
        %{kind: "stage", stage: stage, state: state} ->
          IO.puts("[stage] #{stage} · #{state}")
          {:cont, nil}

        %{data: %{"type" => "result", "result" => text}} ->
          IO.puts("\nDONE: #{text}")
          {:halt, text}

        _ ->
          {:cont, nil}
      end
    end)
    ```

=== "shell"

    ```bash
    curl -sN "$AOD_BASE_URL/api/conversations/$CONV/stream?streams=stdout" \
      -H "Authorization: Bearer $AOD_TOKEN" \
    | awk '/^data: /{sub(/^data: /,""); print}' \
    | jq -r '.data | fromjson? |
        if .type == "assistant" then
          (.message.content[]? | select(.type == "text") | .text)
        elif .type == "result" then
          "FINAL: " + .result
        else empty end'
    ```

---

## 6. Self-spawning agents (sub-agents)

Agents inside sprites can call back to the API and spawn more conversations. The bundled `aod` skill (auto-mounted in every sprite) gives the agent the URL and token — patterns are typically **shell-only** because that's what's running inside a sprite, but the same SDK can be installed inside the sprite via the environment's `setup_script` if you'd rather.

```bash
# Inside the parent agent's sprite
ids=$(printf '%s\n' "What is X?" "What is Y?" "What is Z?" \
  | xargs -n1 -P8 -I{} sh -c '
    curl -s -X POST "$1/api/conversations" \
      -H "Authorization: Bearer $2" -H "Content-Type: application/json" \
      -d "$(jq -n --arg a "$3" --arg p "$4" "{agent_id:\$a, prompt:\$p}")" \
    | jq -r .data.id
  ' _ "$AOD_BASE_URL" "$AOD_TOKEN" "$RESEARCHER_AGENT_ID" {})

# wait + gather (same pattern as example 2)
```

The parent sees the children's answers, synthesizes, returns to its caller. Children's sprites are entirely separate — no shared filesystem, no shared context, no ability to interfere with each other. See [Concepts → Spawning sub-agents](concepts/spawning.md) for the full skill.

---

## 7. Declarative agents and environments

Stop creating things via the API. Define a manifest, apply it. **CLI only** (the `aod` escript handles upserts):

```yaml
# aod.yml
---
apiVersion: aod/v1
kind: Environment
metadata: { name: ravi-hq }
spec:
  packages:
    apt: [jq, ripgrep]
  setup_script: cd /workspace && uv sync

---
apiVersion: aod/v1
kind: Agent
metadata: { name: docs-writer }
spec:
  runtime: claude
  model: anthropic/claude-sonnet-4-6
  environment: ravi-hq
  system: |
    You are a documentation agent. Find one high-value doc fix, open a PR, stop.
  skills: [aod]
  mcp_servers:
    github: { type: http, url: https://api.githubcopilot.com/mcp/ }
```

```bash
./aod apply -f aod.yml
# env  +  ravi-hq
# agent +  docs-writer
```

Idempotent — re-applying is a no-op. Drop in CI to keep your team's agent fleet in source control. See [Concepts → Manifest](concepts/manifest.md) for the full shape.

---

## More

- [Concepts → Manifest](concepts/manifest.md) for the full `aod.yml` reference.
- [Concepts → Spawning](concepts/spawning.md) for the sub-agent skill in detail.
- [SDKs](sdks/python.md) for the typed reference for each language.
