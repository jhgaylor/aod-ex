# Spec-driven development with AoD

The gap in most agent workflows isn't the LLM. It's the interface.

You write a prompt. The agent starts working. Two days later you review the PR and realize it optimized for what you *said* rather than what you *meant*. You re-prompt. The agent rewrites. You re-review. The loop drains time that should go into shipping.

The root cause: prompts are a lossy encoding of requirements. They're ephemeral, undiffable, untestable, and invisible to the agent once a new turn starts.

Specs fix this.

**[Try the interactive demo &rarr;](spec-driven-demo.html)**{ .md-button .md-button--primary }

## What changes with specs

A spec is a structured requirement with a stable ID. Something like [acai.sh](https://acai.sh)'s `feature.yaml`:

```yaml
id: AUTH-001
title: Magic link login
description: Users can log in via email magic link without setting a password.
acceptance_criteria:
  - POST /auth/magic_link generates a 6-digit token stored in Redis, TTL 15 minutes
  - Email is sent via the configured mailer
  - GET /auth/confirm?token=... exchanges the token for a session cookie
  - Token is invalidated after use
  - Expired tokens return 401 with a user-readable error
```

The spec lives in the repo. It's versioned. It's diffable. And crucially, it's a stable reference the agent can cite when it's done: *"I implemented AUTH-001: token generation in `lib/auth/magic_link.ex:24`, email dispatch in `lib/mailer/templates.ex:87`."*

That reference is checkable. Grep for `AUTH-001` in the codebase and see exactly what was touched. A coverage tool can tell you which requirements have code, which have tests, and which have neither.

## How AoD + acai.sh fit together

AoD gives you the runtime. acai.sh gives you the spec layer. Together:

1. **Spec authored** — a developer writes or updates a `feature.yaml` in the repo.
2. **Agent fires automatically** — a webhook or CI step triggers an AoD conversation with the spec as context.
3. **Agent works anchored to requirements** — the prompt includes the spec ID and full criteria; the agent is instructed to tag every relevant change with the requirement ID.
4. **Coverage tracked** — acai.sh (or your own tooling) scrapes the ACID tags to show which requirements are in code, in tests, and approved by a human reviewer.
5. **Spec changes re-trigger** — if `AUTH-001` is updated, the agent re-runs. Drift is structurally impossible.

The agent isn't chasing a prompt anymore. It's filling in a checklist — and the checklist is the source of truth.

## Wiring it up

### 1. Define the spec

```yaml
# specs/auth/magic_link.yaml
id: AUTH-001
title: Magic link login
acceptance_criteria:
  - POST /auth/magic_link generates a 6-digit token stored in Redis, TTL 15 minutes
  - Email is sent via the configured mailer
  - GET /auth/confirm?token=... exchanges the token for a session cookie
  - Token is invalidated after use
  - Expired tokens return 401 with a user-readable error
```

### 2. Define the agent

```bash
curl -X POST $BASE/api/agents \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -d '{
    "name": "spec-implementer",
    "model": "anthropic/claude-sonnet-4-6",
    "runtime": "claude",
    "environment_id": "<your-env-id>",
    "system_prompt": "You implement requirements from spec files. For each acceptance criterion you satisfy, add a comment with the spec ID (e.g. # AUTH-001) near the implementation. When done, summarize which file and line satisfies each criterion."
  }'
```

### 3. Fire it on spec commit (GitHub Actions)

```yaml
# .github/workflows/implement-specs.yml
on:
  push:
    paths:
      - 'specs/**/*.yaml'

jobs:
  implement:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 2
      - name: Fire AoD agent per changed spec
        env:
          AOD_BASE_URL: ${{ secrets.AOD_BASE_URL }}
          AOD_TOKEN: ${{ secrets.AOD_TOKEN }}
          SPEC_IMPLEMENTER_AGENT_ID: ${{ secrets.SPEC_IMPLEMENTER_AGENT_ID }}
        run: |
          git diff --name-only HEAD~1 HEAD -- 'specs/**/*.yaml' | while read spec_file; do
            spec_content=$(cat "$spec_file")
            spec_id=$(grep '^id:' "$spec_file" | awk '{print $2}')

            conv_id=$(curl -s -X POST $AOD_BASE_URL/api/conversations \
              -H "Authorization: Bearer $AOD_TOKEN" \
              -H 'content-type: application/json' \
              -d "{
                \"agent_id\": \"$SPEC_IMPLEMENTER_AGENT_ID\",
                \"prompt\": \"Implement spec $spec_id. Tag each criterion with a comment containing the spec ID. Open a PR when done.\\n\\n$spec_content\"
              }" | jq -r '.id')

            echo "Triggered conversation $conv_id for spec $spec_id"
          done
```

### 4. Track coverage with acai.sh

```bash
# After the agent's PR merges, check coverage
acai coverage --spec-dir specs/ --source-dir lib/

# AUTH-001  magic link login
#   ✓ POST /auth/magic_link         lib/auth/magic_link.ex:24
#   ✓ Email dispatch                lib/mailer/templates.ex:87
#   ✓ GET /auth/confirm             lib/auth/magic_link_controller.ex:12
#   ✓ Token invalidation            lib/auth/magic_link.ex:41
#   ✗ Expired token 401 response    NOT FOUND
```

One requirement missing. You see it immediately, re-trigger, and it's fixed — no grep, no reading the PR top to bottom.

## What this unlocks

**Agents that can be audited.** Every agent action is traceable to a requirement. "Why did the agent change this file?" has a one-line answer: `AUTH-001, criterion 3`.

**Specs as the unit of work.** Instead of one giant prompt with 20 requirements, each spec is a separate conversation. Parallel fan-out is natural: one agent per spec, all running simultaneously.

```bash
# Fan out: all changed specs in parallel
git diff --name-only HEAD~1 HEAD -- 'specs/**/*.yaml' | while read f; do
  fire_agent "$f" &
done
wait
```

**Incremental re-implementation.** When a spec changes, only that spec's agent re-runs. The rest of the codebase is untouched.

**Human approval that means something.** Instead of "LGTM" on a 40-file diff, reviewers sign off on individual requirements. The acai.sh dashboard shows per-requirement status: implemented, tested, approved. Nothing reaches `accepted` unless a human has explicitly signed off on each criterion.

**LLM-agnostic.** Because the spec is the contract — not the prompt — you can swap the agent's runtime (claude → codex → gemini) without rewriting requirements. The spec is stable; the agent is interchangeable.

## The limits

This works well for feature work with clear acceptance criteria. It works less well for:

- **Exploratory work** where requirements aren't known upfront — you need a discovery agent first, to write the spec.
- **Refactoring without success criteria** — "make this faster" isn't a spec. Benchmark before and after is.
- **Large cross-cutting requirements** — specs that touch many interacting components benefit from being decomposed before the agent fires. One spec per agent works; one spec for half the codebase doesn't.

The agent is only as good as the spec. Garbage in, garbage out — but at least the garbage is versioned and auditable.

## Getting started

The pieces exist today:

1. Add [acai.sh](https://acai.sh) to your repo to start writing `feature.yaml` specs
2. [Deploy AoD](install.md) and create an agent with a spec-aware system prompt
3. Wire the GitHub Actions trigger (see above)
4. Watch coverage fill in as agents implement requirements

The integration isn't packaged as a one-click install yet. That's the roadmap.

---

*See [Examples](examples.md) for more agent workflow patterns.*
