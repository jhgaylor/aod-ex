# Secrets managers

`aod apply` resolves secret values at apply time — before writing anything to the database — so you can commit `aod.yml` without embedding credentials.

Any value under `spec.secrets` can be a URI reference. Resolution runs on the operator's machine using the relevant CLI. AoD never sees your vault password or access token.

## URI schemes

| Scheme | Format | Auth | CLI |
|--------|--------|------|-----|
| `op://` | `op://<vault>/<item>/<field>` | `op` session / biometric / service account | [1Password CLI](https://developer.1password.com/docs/cli/get-started) |
| `bws://` | `bws://<secret-uuid>` | `BWS_ACCESS_TOKEN` env var | [Bitwarden Secrets Manager CLI](https://bitwarden.com/help/secrets-manager-cli/) |
| `infisical://` | `infisical://<project?>/<env>/<path?>/<name>` | `INFISICAL_TOKEN` or `infisical login` | [Infisical CLI](https://infisical.com/docs/cli/overview) |
| `${VAR}` | `${ENV_VAR_NAME}` | operator shell / `--var` flag | — |

`${VAR}` substitution runs before external resolvers, so references can be composed:

```yaml
secrets:
  ANTHROPIC_API_KEY: op://${OP_VAULT}/Anthropic/api_key   # ${OP_VAULT} substituted first
```

Use `$${VAR}` to write a literal `${VAR}`.

Resolution scoped to `spec.secrets` only. Other manifest fields use the provision-time substitution layer at sprite spawn.

---

## 1Password

### Prerequisites

- A 1Password account and the `op` CLI: https://developer.1password.com/docs/cli/get-started

```bash
brew install 1password-cli   # macOS
```

### Auth

**Interactive:** `op signin` before each `aod apply` session (session TTL: 30 min by default).

**CI (service account):**

```bash
export OP_SERVICE_ACCOUNT_TOKEN=ops_...
./aod apply -f aod.yml
```

### URI format

```
op://<vault>/<item>/<field>
```

Find names with `op item list --vault <vault>` and `op item get <item> --vault <vault>`.

### Example

```yaml
secrets:
  ANTHROPIC_API_KEY: op://Work/Anthropic/api_key
  GITHUB_TOKEN: op://Personal/GitHub/token
  POSTHOG_API_KEY: op://${OP_VAULT}/PostHog/api_key    # dynamic vault
```

```bash
op signin
OP_VAULT=Work ./aod apply -f aod.yml
```

### Errors

| Message | Fix |
|---------|-----|
| `` `op` not on PATH `` | Install op CLI |
| `session expired` | Run `op signin` again |
| `item not found in vault` | Check vault/item/field names with `op item list` |

---

## Bitwarden Secrets Manager

### Prerequisites

- A Bitwarden Secrets Manager account (not the personal vault): https://bitwarden.com/products/secrets-manager/
- The `bws` CLI: https://bitwarden.com/help/secrets-manager-cli/

```bash
brew install bitwarden/brew/bws   # macOS
```

### Auth

Generate a machine access token in the dashboard (**Machine Accounts** → **New machine account**). Set it before applying:

```bash
export BWS_ACCESS_TOKEN=0.your-token-here...
./aod apply -f aod.yml
```

### URI format

```
bws://<secret-uuid>
```

Find UUIDs with `bws secret list` or in the dashboard (hover a secret → copy ID).

### Example

```yaml
secrets:
  GITHUB_TOKEN: bws://be8e0ad8-1234-5678-90ab-cdef01234567
  ANTHROPIC_API_KEY: bws://f3a21b09-abcd-ef01-2345-678901234567
```

```bash
BWS_ACCESS_TOKEN=0.your-token... ./aod apply -f aod.yml
```

### Errors

| Message | Fix |
|---------|-----|
| `` `bws` not on PATH `` | Install bws CLI |
| `invalid access token` | Check `BWS_ACCESS_TOKEN`; rotate token if expired |
| `resource not found` | Verify UUID and machine account access |
| `bws:// reference is missing the UUID` | Add the UUID after `bws://` |

---

## Infisical

### Prerequisites

- An Infisical account: https://app.infisical.com or self-hosted
- The `infisical` CLI: https://infisical.com/docs/cli/overview

```bash
brew install infisical/get-cli/infisical   # macOS
```

### Auth

**Interactive (local dev):**

```bash
infisical login    # authenticate
infisical init     # creates .infisical.json — binds working dir to a project
./aod apply -f aod.yml
```

**CI / headless:**

```bash
export INFISICAL_TOKEN=st.your-token-here...
./aod apply -f aod.yml
```

### URI format

```
infisical://<project-id>/<env>/<name>
infisical://<project-id>/<env>/<folder>/<name>
infisical:///<env>/<name>                         # empty project → .infisical.json / INFISICAL_PROJECT_ID
```

| Segment | Description |
|---------|-------------|
| `project-id` | Project UUID (or empty — falls back to `.infisical.json`/`INFISICAL_PROJECT_ID`) |
| `env` | Environment slug (`dev`, `staging`, `prod`) |
| `folder` | Optional folder path (one or more segments) |
| `name` | Secret name (always the last segment) |

Find your project ID in **Project Settings** or with `infisical projects list`.

### Example

```yaml
secrets:
  DATABASE_URL: infisical://abc123/prod/api/DATABASE_URL   # explicit project
  REDIS_URL: infisical:///prod/REDIS_URL                   # workspace project
  NPM_TOKEN: infisical:///prod/npm/NPM_TOKEN               # folder path
```

```bash
# local dev
infisical login && infisical init
./aod apply -f aod.yml

# CI
INFISICAL_TOKEN=st.your-token... ./aod apply -f aod.yml
```

### Errors

| Message | Fix |
|---------|-----|
| `` `infisical` not on PATH `` | Install infisical CLI |
| `Unauthorized` | Re-login or check `INFISICAL_TOKEN` |
| `invalid infisical:// reference` | URI needs at least `/<env>/<name>` |
| `Could not find project` | Check project ID in Project Settings |
| `secret not found` | Check env slug, folder path, and secret name (case-sensitive) |
