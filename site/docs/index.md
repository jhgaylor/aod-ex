---
hide:
  - navigation
  - toc
---

# Spawn coding agents in fresh sandboxes, on demand.

**One API call. One sprite. One agent. One bill at the end.**

Agent on Demand is the operations plane underneath products that need to fan out coding work to LLMs in isolated environments. You hit a single endpoint with a prompt; we provision a microVM, mount your skills and MCP servers, run the runtime CLI of your choice (Claude Code, Codex, Gemini, opencode), stream the output back, and tear it all down when you're done.

[Get started in 5 minutes →](install.md){ .md-button .md-button--primary }
[See the API →](concepts/api.md){ .md-button }

---

## What it looks like

A "code-reviewer" agent: a sandbox with the project repo cloned, jq + ripgrep installed, the GitHub MCP server wired up, then a conversation that hands it a real PR.

=== "Python"

    ```python
    from aod_client import Client

    with Client() as aod:
        # 1. The shape of every sprite this agent runs in.
        env = aod.environments.create(
            name="my-project",
            packages={"apt": ["jq", "ripgrep"]},
            repositories=[{
                "url": "https://github.com/my-org/my-repo",
                "mount_path": "/workspace/my-repo",
                "secret_key": "GITHUB_TOKEN",
            }],
            setup_script="cd /workspace/my-repo && uv sync",
        )
        aod.environments.add_secret(env["id"], "GITHUB_TOKEN", "ghp_xxx")

        # 2. The agent itself — runtime, model, system prompt, skills, MCP.
        agent = aod.agents.create(
            name="code-reviewer",
            runtime="claude",
            model="anthropic/claude-sonnet-4-6",
            environment_id=env["id"],
            system="You are a senior reviewer. One high-value issue per PR, no nits.",
            skills=["aod"],
            mcp_servers={
                "github": {
                    "type": "http",
                    "url": "https://api.githubcopilot.com/mcp/",
                    "headers": {"Authorization": "Bearer ghp_xxx"},
                },
            },
        )

        # 3. Hand it a real task. AoD provisions a fresh sprite, clones the
        #    repo, runs setup_script, starts claude with the prompt on stdin.
        conv = aod.conversations.create(
            agent_id=agent["id"],
            prompt="Review PR #1234 against main. Open a follow-up issue if you find a real problem.",
        )

        print(aod.conversations.wait_for_result(conv["id"]))
    ```

=== "TypeScript"

    ```ts
    import { Client } from "@aod/client";

    const aod = new Client({ token: process.env.AOD_TOKEN! });

    // 1. Environment.
    const env = await aod.environments.create({
      name: "my-project",
      packages: { apt: ["jq", "ripgrep"] },
      repositories: [{
        url: "https://github.com/my-org/my-repo",
        mount_path: "/workspace/my-repo",
        secret_key: "GITHUB_TOKEN",
      }],
      setup_script: "cd /workspace/my-repo && uv sync",
    });
    await aod.environments.addSecret(env.id, "GITHUB_TOKEN", "ghp_xxx");

    // 2. Agent.
    const agent = await aod.agents.create({
      name: "code-reviewer",
      runtime: "claude",
      model: "anthropic/claude-sonnet-4-6",
      environment_id: env.id,
      system: "You are a senior reviewer. One high-value issue per PR, no nits.",
      skills: ["aod"],
      mcp_servers: {
        github: {
          type: "http",
          url: "https://api.githubcopilot.com/mcp/",
          headers: { Authorization: "Bearer ghp_xxx" },
        },
      },
    });

    // 3. Conversation.
    const conv = await aod.conversations.create({
      agent_id: agent.id,
      prompt:   "Review PR #1234 against main. Open a follow-up issue if you find a real problem.",
    });
    console.log(await aod.conversations.waitForResult(conv.id));
    ```

=== "Go"

    ```go
    ctx := context.Background()
    c, _ := aod.New(aod.Config{Token: os.Getenv("AOD_TOKEN")})

    // 1. Environment.
    env, _ := c.Environments.Create(ctx, map[string]any{
        "name":     "my-project",
        "packages": map[string]any{"apt": []string{"jq", "ripgrep"}},
        "repositories": []map[string]any{{
            "url":        "https://github.com/my-org/my-repo",
            "mount_path": "/workspace/my-repo",
            "secret_key": "GITHUB_TOKEN",
        }},
        "setup_script": "cd /workspace/my-repo && uv sync",
    })
    c.Environments.AddSecret(ctx, env.ID, "GITHUB_TOKEN", "ghp_xxx")

    // 2. Agent.
    agent, _ := c.Agents.Create(ctx, map[string]any{
        "name":           "code-reviewer",
        "runtime":        "claude",
        "model":          "anthropic/claude-sonnet-4-6",
        "environment_id": env.ID,
        "system":         "You are a senior reviewer. One high-value issue per PR, no nits.",
        "skills":         []string{"aod"},
        "mcp_servers": map[string]any{
            "github": map[string]any{
                "type":    "http",
                "url":     "https://api.githubcopilot.com/mcp/",
                "headers": map[string]string{"Authorization": "Bearer ghp_xxx"},
            },
        },
    })

    // 3. Conversation.
    conv, _ := c.Conversations.Create(ctx, aod.ConversationCreate{
        AgentID: agent.ID,
        Prompt:  "Review PR #1234 against main. Open a follow-up issue if you find a real problem.",
    })
    text, _ := c.Conversations.WaitForResult(ctx, conv.ID)
    fmt.Println(text)
    ```

=== "Elixir"

    ```elixir
    client = AodClient.new()

    # 1. Environment.
    {:ok, env} = AodClient.Environments.create(client,
      name: "my-project",
      packages: %{apt: ["jq", "ripgrep"]},
      repositories: [%{
        url:        "https://github.com/my-org/my-repo",
        mount_path: "/workspace/my-repo",
        secret_key: "GITHUB_TOKEN"
      }],
      setup_script: "cd /workspace/my-repo && uv sync"
    )
    AodClient.Environments.add_secret(client, env["id"], "GITHUB_TOKEN", "ghp_xxx")

    # 2. Agent.
    {:ok, agent} = AodClient.Agents.create(client,
      name: "code-reviewer",
      runtime: "claude",
      model: "anthropic/claude-sonnet-4-6",
      environment_id: env["id"],
      system: "You are a senior reviewer. One high-value issue per PR, no nits.",
      skills: ["aod"],
      mcp_servers: %{
        "github" => %{
          type: "http",
          url: "https://api.githubcopilot.com/mcp/",
          headers: %{Authorization: "Bearer ghp_xxx"}
        }
      }
    )

    # 3. Conversation.
    {:ok, conv} = AodClient.Conversations.create(client,
      agent_id: agent["id"],
      prompt: "Review PR #1234 against main. Open a follow-up issue if you find a real problem."
    )
    {:ok, text} = AodClient.Conversations.wait_for_result(client, conv["id"])
    IO.puts(text)
    ```

=== "shell"

    The CLI's natural shape for this is a manifest: declare everything as YAML, reconcile with `aod apply`, then start the conversation with one curl.

    ```yaml
    # aod.yml
    ---
    apiVersion: aod/v1
    kind: Environment
    metadata: { name: my-project }
    spec:
      packages: { apt: [jq, ripgrep] }
      repositories:
        - url: https://github.com/my-org/my-repo
          mount_path: /workspace/my-repo
          secret_key: GITHUB_TOKEN
      setup_script: cd /workspace/my-repo && uv sync

    ---
    apiVersion: aod/v1
    kind: Agent
    metadata: { name: code-reviewer }
    spec:
      runtime: claude
      model: anthropic/claude-sonnet-4-6
      environment: my-project
      system: You are a senior reviewer. One high-value issue per PR, no nits.
      skills: [aod]
      mcp_servers:
        github:
          type: http
          url: https://api.githubcopilot.com/mcp/
          headers:
            Authorization: Bearer ghp_xxx
    ```

    ```bash
    # Apply the manifest (idempotent — safe to run in CI).
    ./aod apply -f aod.yml

    # Add the secret out-of-band (manifests don't carry secrets).
    ENV_ID=$(curl -s "$AOD_BASE_URL/api/environments" -H "Authorization: Bearer $AOD_TOKEN" \
      | jq -r '.data[] | select(.name=="my-project") | .id')
    curl -s -X POST "$AOD_BASE_URL/api/environments/$ENV_ID/secrets" \
      -H "Authorization: Bearer $AOD_TOKEN" -H "Content-Type: application/json" \
      -d '{"key":"GITHUB_TOKEN","value":"ghp_xxx"}'

    # Spawn the conversation.
    AGENT_ID=$(curl -s "$AOD_BASE_URL/api/agents" -H "Authorization: Bearer $AOD_TOKEN" \
      | jq -r '.data[] | select(.name=="code-reviewer") | .id')
    curl -s -X POST "$AOD_BASE_URL/api/conversations" \
      -H "Authorization: Bearer $AOD_TOKEN" -H "Content-Type: application/json" \
      -d "$(jq -n --arg a "$AGENT_ID" --arg p "Review PR #1234 against main. Open a follow-up issue if you find a real problem." '{agent_id:$a, prompt:$p}')"
    ```

Behind that one conversation call:

1. A fresh microVM gets provisioned and assigned to this conversation
2. The agent's environment is hydrated — packages installed, repos cloned, secrets injected
3. Bundled skills and MCP servers are mounted into the runtime
4. The CLI is spawned with your prompt; stdout/stderr stream back as line-delimited JSON over SSE
5. The agent does work — runs commands, reads files, edits code, calls tools, opens PRs
6. You get the answer

The environment + agent only get defined once; subsequent conversations reuse them. Each sandbox is genuinely isolated — an agent that wants to `rm -rf /` is just blowing up its own VM.

---

## Built for production agent workflows

<div class="grid cards" markdown>

-   :material-shield-check:{ .lg } **Sandboxed by default**

    Every conversation runs in its own short-lived VM. No shared state, no escape vectors into your infrastructure, no agents reaching across each other's work.

-   :material-puzzle:{ .lg } **Multi-runtime**

    First-class support for Claude Code, OpenAI Codex, Google Gemini, and opencode. Switch runtimes per agent — no code changes for the caller. Compare outputs across providers on the same task.

-   :material-restart:{ .lg } **Stateful sprites**

    Long-running sandboxes that persist between turns. Send follow-up prompts; the runtime resumes its session with full context. BEAM crash mid-turn? Boot the server back up — conversations rehydrate from the running VM and keep streaming.

-   :material-file-document-edit:{ .lg } **Declarative**

    Define your agents and environments in a YAML manifest. `aod apply -f aod.yml` reconciles the running instance — same shape across the API, the CLI, and the LiveView UI. Idempotent. Source-control friendly.

-   :material-toolbox:{ .lg } **Skills + MCP, normalized**

    Configure skills (mounted instructional context) and MCP servers once on an agent; the runtime hooks land in whichever flavor each CLI expects (Claude's `~/.claude.json`, Codex's `~/.codex/config.toml`, Gemini's `~/.gemini/settings.json`, opencode's JSON config). You don't have to know the per-runtime quirks.

-   :material-server-network:{ .lg } **Single-tenant by design**

    You self-host. Your data, your tokens, your bill. Deploy with `mix aod.up` (one command, your own AoD running in a sprite) or via the included `render.yaml`.

</div>

---

## When it fits

You're building something that needs to delegate coding work to an LLM in a real environment, repeatedly, in parallel, or in long sessions. Examples:

- **Per-PR review or audit fleets.** Spawn one agent per service, repository, or PR. Each runs in isolation with its own clone and context.
- **Long-running coding tasks** that need to install packages, write files, run tests, open PRs — work that doesn't fit in a single API call to an LLM provider.
- **Multi-runtime comparison.** Send the same prompt to a Claude agent and a Codex agent, compare results in production, pick the winner per task type.
- **Customer-scoped sandboxes.** A SaaS product where each customer's task gets its own VM with their secrets and code, never leaking across.
- **Self-spawning agents.** Agents inside sprites can call back to spawn more agents — a planning agent fans out research to a swarm of specialized researchers, gathers their answers, returns one synthesized response.

It's **not** a chatbot frontend, an IDE, or a general-purpose VM provider. It's the layer between *"I want an LLM to do real work"* and *"I have a fleet of fresh VMs and the bill at the end of the month."*

---

## What you get

| | |
|---|---|
| **REST API** | Stable, OpenAPI-spec'd. Live Swagger UI on every running instance. |
| **LiveView UI** | Watch conversations stream in real time. Per-stage timing. Pretty / raw / chat-style log views. Browse history. |
| **CLI** | Single-binary `aod`. List, stream, prompt, terminate, apply manifests. Works from any sprite or any laptop. |
| **SDKs** | First-party clients for [Python](sdks/python.md), [TypeScript](sdks/typescript.md), [Go](sdks/go.md), and [Elixir](sdks/elixir.md). Thin, idiomatic, no codegen baggage. |
| **In-app docs** | `/help` route on every running instance. Matches your deploy's version. Covers operating, manifest, spawning, every concept. |
| **OpenTelemetry** | TRACEPARENT propagation into the sprite, model API calls as child spans of turn spans. Works with any OTLP backend. |

---

## Ready?

[Install in 5 minutes →](install.md){ .md-button .md-button--primary }
[Read the docs →](quickstart.md){ .md-button }
[Browse the source →](https://github.com/jhgaylor/aod-ex){ .md-button }

<small>Built on Phoenix + [Sprites](https://sprites.dev). MIT license. Single-tenant. Self-hosted.</small>
