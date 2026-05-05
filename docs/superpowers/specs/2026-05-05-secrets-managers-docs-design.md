---
name: Secrets Managers Docs
description: Design spec for adding Infisical, 1Password, and BWS integration docs to agent-on-demand
type: project
---

# Secrets Manager Docs — Design Spec

## Goal

Add dedicated documentation for using Infisical, 1Password CLI (`op`), and Bitwarden Secrets Manager (`bws`) with `aod apply`. The feature already exists in the codebase; the docs don't.

## What already exists

`priv/help/manifest.md` has a section "Apply-time secret resolution" that covers all three URI schemes in a reference table. The new docs expand on this with per-tool setup/auth guides and are discoverable on their own.

## Files to create

### Canonical source: `priv/help/`

These are the authoritative copies. The sync script mirrors them to `site/docs/`.

```
priv/help/secrets-managers.md           # index: concept + URI reference table + links
priv/help/secrets/1password.md          # 1Password: install op, auth, URI syntax, examples
priv/help/secrets/bws.md                # Bitwarden: install bws, BWS_ACCESS_TOKEN, UUID lookup, examples
priv/help/secrets/infisical.md          # Infisical: install CLI, login vs token auth, URI syntax, examples
```

### Operator reference: `docs/`

A single comprehensive guide for GitHub browsing / operator use. Covers all three tools in one document with full examples, error messages, and troubleshooting.

```
docs/secrets-managers.md
```

### Site: `site/docs/` (via sync)

Updated `site/sync_content.sh` copies the four `priv/help/secrets*` files to:

```
site/docs/concepts/secrets-managers.md
site/docs/concepts/secrets/1password.md
site/docs/concepts/secrets/bws.md
site/docs/concepts/secrets/infisical.md
```

`mkdocs.yml` nav gets a new "Secrets managers" group under Docs > Concepts.

## Content structure per file

### `secrets-managers.md` (index — all locations)

1. One-paragraph concept: apply-time resolution, why you'd use it (commit YAML without secrets)
2. URI scheme reference table (all three: scheme, format, auth mechanism)
3. Composition example (`op://${OP_VAULT}/...`)
4. Links to per-tool pages

### `secrets/1password.md`

1. Prerequisites: 1Password account, `op` CLI install link
2. Auth: `op signin` / biometric unlock — `op` handles it, AoD doesn't touch credentials
3. URI format: `op://<vault>/<item>/<field>` with explanation of each segment
4. Finding vault/item/field names in the 1Password UI vs `op item list`
5. Full `aod.yml` example (Environment + Vault with `op://` refs)
6. Running `aod apply`
7. Troubleshooting: session expired, item not found

### `secrets/bws.md`

1. Prerequisites: Bitwarden Secrets Manager account, `bws` CLI install link
2. Auth: `BWS_ACCESS_TOKEN` env var — where to generate it in the dashboard
3. URI format: `bws://<secret-uuid>` — UUIDs from `bws secret list` or the dashboard
4. Full `aod.yml` example
5. Running `aod apply` with `BWS_ACCESS_TOKEN` set
6. Troubleshooting: invalid token, UUID not found

### `secrets/infisical.md`

1. Prerequisites: Infisical account (cloud or self-hosted), `infisical` CLI
2. Auth: two options
   - Interactive: `infisical login` + `.infisical.json` for project binding
   - CI/headless: `INFISICAL_TOKEN` env var
3. URI format: `infisical://<project>/<env>/<path>/<name>` with segment breakdown
   - Empty project segment falls through to `.infisical.json` / `INFISICAL_PROJECT_ID`
   - Last segment is always the secret name; middle segments form the folder path
4. Full `aod.yml` example (explicit project + workspace-bound)
5. Running `aod apply`
6. Troubleshooting: token expired, project not found, path vs name confusion

### `docs/secrets-managers.md`

Same content as the index + all three tool sections merged into one document. Structured with `##` per tool. Includes error output examples from the apply failure modes (session expired, invalid token, etc.).

## Sync script changes

Add to `site/sync_content.sh`:

```bash
echo "Syncing secrets manager pages from priv/help/..."
mkdir -p docs/concepts/secrets
cp -v ../apps/agent_on_demand/priv/help/secrets-managers.md docs/concepts/secrets-managers.md
cp -v ../apps/agent_on_demand/priv/help/secrets/1password.md docs/concepts/secrets/1password.md
cp -v ../apps/agent_on_demand/priv/help/secrets/bws.md       docs/concepts/secrets/bws.md
cp -v ../apps/agent_on_demand/priv/help/secrets/infisical.md docs/concepts/secrets/infisical.md
```

## Nav changes (`mkdocs.yml`)

Under `nav > Docs > Concepts`, add:

```yaml
- Secrets managers:
    - Overview: concepts/secrets-managers.md
    - 1Password: concepts/secrets/1password.md
    - Bitwarden (bws): concepts/secrets/bws.md
    - Infisical: concepts/secrets/infisical.md
```

## What this PR does NOT do

- No code changes — the resolver logic already exists in `apply.ex`
- No changes to `priv/help/manifest.md` — it stays as the authoritative URI reference; new docs link back to it
- No new secret providers

## Success criteria

1. `aod help secrets-managers` (or `aod help secrets`) shows useful output
2. The MkDocs site builds without errors after running `sync_content.sh`
3. A user unfamiliar with each tool can follow one page end-to-end and successfully run `aod apply`
