---
hide:
  - navigation
  - toc
---

# Agent on Demand

A REST API for spawning AI coding agents inside [Sprite](https://sprites.dev) microVMs.

```bash
curl -X POST $AOD_BASE_URL/api/conversations \
  -H "Authorization: Bearer $AOD_TOKEN" \
  -d '{"agent_id":"...","prompt":"Audit the api service for SQL injection."}'
```

That call provisions a fresh sandboxed VM, mounts your skills, runs the runtime CLI of your choice (claude / codex / gemini / opencode), streams the output back as SSE, and tears down when you're done. One conversation, one sprite, one bill.

[Get started →](install.md){ .md-button .md-button--primary }
[Browse the API →](concepts/api.md){ .md-button }

---

## Why

- **Multi-runtime.** Configure agents against four CLIs (Anthropic Claude Code, OpenAI Codex, Google Gemini, opencode). Switch one field, no other code changes.
- **Sandboxed by default.** Every conversation runs in its own short-lived VM, so an agent that wants to `rm -rf /` can — it's just blowing up its own sandbox.
- **Stateful sprites.** Long-lived sandboxes that survive between turns; runtime sessions resume across server restarts.
- **Declarative.** Define your agents and environments as YAML and `aod apply` them. Same shape across the API, the CLI, and the UI.
- **Single-tenant by design.** You self-host. Your data, your tokens, your bill.

## What you get

| | |
|---|---|
| **A REST API** | Live OpenAPI spec + Swagger UI on every running instance. |
| **A LiveView UI** | Watch conversations stream in real time, see provisioning timing per stage, browse history. |
| **A CLI** | Single-binary `aod` (escript) for the operator side — list, stream, prompt, terminate, apply manifests. |
| **SDKs** | First-party clients for [Python](sdks/python.md), [TypeScript](sdks/typescript.md), [Go](sdks/go.md), and [Elixir](sdks/elixir.md). |
| **A docs site** | This one. Plus an in-app `/help` route on every running instance. |

## Where this fits

It's the layer between *"I want an LLM to do something with code"* and *"I have a fleet of fresh VMs and a bill at the end of the month."* If you're building a product that needs to fan out coding work to LLMs in isolated environments, this is the operations plane underneath.

It is **not** an end-user product. There's no UI to chat with — the UI is for watching the work agents are doing. End users hit your product, your product hits AoD.

---

<small>Built on Phoenix + Sprites. [Source on GitHub](https://github.com/ravi-hq/agent-on-demand-ex). MIT license.</small>
