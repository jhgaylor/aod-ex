# Why Agent on Demand

You've already got an LLM provider. You've got an API key. You can hit `api.anthropic.com` from your application server today. So what's this for?

## The gap between LLM API and "agent doing real work"

LLM provider APIs give you a single round-trip: prompt in, completion out. That's enough for autocomplete, classification, summarization. It's nowhere near enough for an *agent* — something that reads files, runs commands, edits code, calls tools, fixes its own mistakes across many turns.

To get from one to the other, you need:

- A **real shell** the agent can actually run code in
- A **filesystem** that survives between turns
- **Network access** the agent can use, scoped to what's safe
- **Tools** — git, language toolchains, package managers, MCP servers
- **Isolation** — the agent should be able to `rm -rf /` without consequence
- **Lifecycle** — sessions that resume across turns, sandboxes that get torn down when done
- **Observability** — what did the agent do, how long did it take, what did it cost

You can build all of that yourself on top of bare cloud VMs or container services. Plenty of teams have. It's a lot of plumbing — and most of it isn't differentiating work for whatever you're actually building.

Agent on Demand is that plumbing, packaged.

## Why not just use the provider's CLI directly

You can absolutely run `claude` or `codex` on your own machine. It's even great for personal use.

What you can't do, easily:

- **Multi-tenancy.** Run hundreds of customer tasks in parallel without them sharing a filesystem.
- **Provisioning.** Spin a fresh, configured workspace per task — packages installed, repos cloned, secrets injected — and tear it down when done.
- **Long-running fan-out.** Spawn 50 agents in parallel, each with their own VM, and gather their results.
- **Multi-runtime arbitrage.** Send the same prompt to four different runtimes and compare. Switch runtimes per task type. Add a new runtime in a week.
- **A stable HTTP surface** for your application to call. The CLIs are interactive tools, not APIs.
- **Audit and observability.** Per-turn timing, per-stage cost, per-agent token usage, OTel spans connecting your request to the LLM provider's API call.

## Why not Anthropic's `code execution` tool / sandboxed APIs

Provider-bundled sandboxes are tied to one provider. They're a sealed box: you don't get to choose the runtime, install your own packages, mount your own MCP servers, or hold a sandbox open across many turns.

AoD is opinionated about agents but unopinionated about which provider you use. The same agent definition works against Claude, Codex, Gemini, or opencode — you control what runs inside, what's installed, how it's networked, what tools it has access to.

If you're committed to one provider's sandbox, you don't need this. If you want to keep your options open — or if you need to do real provisioning before the LLM starts — you do.

## Why not E2B / Modal / generic sandbox-as-a-service

Generic sandbox services give you a VM. They don't know what an agent is. You're the one orchestrating "spawn the runtime CLI with the right flags, stream stdout, parse stream-json, pair tool_use with tool_result, capture the final answer, persist the runtime session id, resume on next turn..."

That's the loop AoD is. Your application stays at the level of *"start a conversation, here's the prompt, give me the answer."*

If you have one task type and want maximum flexibility, building on a generic sandbox provider is fine. If you have many task types and want to ship the *agent product*, AoD is shorter.

## Why self-host

There's no hosted AoD. Two reasons:

1. **The token blast radius is real.** An agent inside a sprite has the admin token. We don't yet have scoped child tokens (it's on the roadmap, but until then, prompt injection inside an agent is a privilege escalation across your AoD instance).
2. **Your sprites have your code.** Per-environment secrets, your private repos, your customer data. Single-tenant means you own where it sits.

Deploy is one command (`mix aod.up`) or one Render service. The bill is your sprites + your LLM provider, no AoD-side markup.

## When it doesn't fit

- You only need one-shot LLM completions. Stick with the provider API.
- You're building a chatbot. There's no UI here for end users to chat with.
- You're a single developer using one CLI on one machine. The CLI itself is fine.
- You can't tolerate self-hosting. Wait for hosted, or use a hosted competitor.

If those don't disqualify you, [install it](install.md) and try a conversation.
