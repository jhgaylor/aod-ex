# Declarative manifest (`aod apply`)

For more than a handful of agents/environments, manage them as YAML and reconcile via the CLI.

## Format

A `aod.yml` is a multi-document YAML file. Each doc is one resource with three top-level fields:

```yaml
apiVersion: aod/v1
kind: Environment | Vault | Agent
metadata:
  name: <unique-on-operator-side>
spec:
  # ... fields matching the API schema for the kind ...
```

The `metadata.name` is the upsert key. If a resource with that name exists, it's PUT; if not, it's POSTed.

## Order is irrelevant inside the file

`aod apply` reconciles **environments first, vaults second, agents last** — so an agent doc can reference an environment by name (`spec.environment: my-env`) even if that environment is defined later in the file. Vaults aren't referenced from agents (they're picked per-conversation), so the order between envs and vaults doesn't matter functionally; the predictable ordering just makes the apply output easier to skim.

## Example

```yaml
---
apiVersion: aod/v1
kind: Environment
metadata:
  name: ravi-hq
spec:
  packages:
    apt: [jq, ripgrep]
  setup_script: cd /workspace && uv sync

---
apiVersion: aod/v1
kind: Vault
metadata:
  name: alice
spec:
  description: Alice's credentials
  secrets:
    GITHUB_TOKEN: ghp_alice_...
    NPM_TOKEN: npm_alice_...

---
apiVersion: aod/v1
kind: Agent
metadata:
  name: researcher
spec:
  runtime: claude
  model: anthropic/claude-sonnet-4-6
  environment: ravi-hq        # ← resolved to environment_id at apply time
  system: You are a research assistant.
  skills: [aod]
  mcp_servers:
    everything:
      command: npx
      args: ["-y", "@modelcontextprotocol/server-everything"]
```

## Apply

```bash
./aod apply -f aod.yml
```

Output uses `+` for create, `~` for update, one line per resource:

```
env    +  ravi-hq
vault  +  alice
  secret  ~  alice/GITHUB_TOKEN
  secret  ~  alice/NPM_TOKEN
agent  ~  researcher
```

Errors per-resource go to stderr but don't stop the run; other resources still apply.

## Idempotency

Re-applying the same file is a no-op (every resource shows `~` because we always PUT, but the spec doesn't change). Useful for CI: keep `aod.yml` in source control, run `aod apply -f aod.yml` from your deploy pipeline.

## Heads up: secrets

The shape we accept doesn't yet have a way to reference secrets without inlining them. If your manifest contains MCP server bearer tokens, **don't commit it** — `aod.yml` is in the project's default `.gitignore`. A `${ENV_VAR}` substitution pass is on the wishlist.
