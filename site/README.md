# Static docs site

MkDocs Material site published to GitHub Pages.

## How content is sourced

Most pages aren't authored here — they're mirrored from elsewhere in the repo so we don't carry two divergent forests:

| Site path | Source |
| --- | --- |
| `docs/quickstart.md` | `priv/help/quickstart.md` |
| `docs/concepts/*.md` | `priv/help/{agents,environments,manifest,spawning,api}.md` |
| `docs/operating/*.md` | `docs/{runbook,deploy}.md` |
| `docs/sdks/*.md` | `clients/{python,typescript,go,elixir}/README.md` |

The site-only pages (`docs/index.md`, `docs/install.md`) are tracked here as canonical.

`sync_content.sh` does the copying. Synced pages are gitignored under `site/.gitignore` so they never accumulate stale duplicates in source control. The CI workflow (`.github/workflows/docs.yml`) runs the sync before `mkdocs build`.

## Build locally

```bash
pip install mkdocs mkdocs-material

cd site
./sync_content.sh
mkdocs serve   # http://127.0.0.1:8000
```

`mkdocs serve` watches the docs directory; rerun `./sync_content.sh` after editing one of the source files in `priv/help/`, `docs/`, or `clients/*/`.

## Deploy

GitHub Actions (`docs.yml`) runs on every push to `main` that touches:
- `site/**`
- `priv/help/**`
- `docs/**`
- `clients/*/README.md`

It syncs, builds, uploads as a Pages artifact, and deploys.

To publish first time: enable Pages in repo settings → "Build and deployment" → source: "GitHub Actions". The workflow does the rest.
