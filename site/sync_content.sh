#!/usr/bin/env bash
# Mirror in-repo markdown into site/docs/ so we don't have two
# divergent copies of the same content. Hand-authored pages
# (index.md, install.md, quickstart.md) live in site/docs/ as the
# canonical copy and are NOT touched by this script.
#
# Run this before `mkdocs build` (the docs CI workflow does it).

set -euo pipefail

cd "$(dirname "$0")"

echo "Syncing quickstart + concept pages from priv/help..."
cp -v ../priv/help/quickstart.md  docs/quickstart.md
cp -v ../priv/help/agents.md      docs/concepts/agents.md
cp -v ../priv/help/environments.md docs/concepts/environments.md
cp -v ../priv/help/manifest.md    docs/concepts/manifest.md
cp -v ../priv/help/spawning.md    docs/concepts/spawning.md
cp -v ../priv/help/api.md         docs/concepts/api.md

echo "Syncing operating pages from docs/..."
cp -v ../docs/runbook.md docs/operating/runbook.md
cp -v ../docs/deploy.md  docs/operating/deploy.md

echo "Syncing SDK pages from clients/*/README.md..."
cp -v ../clients/python/README.md     docs/sdks/python.md
cp -v ../clients/typescript/README.md docs/sdks/typescript.md
cp -v ../clients/go/README.md         docs/sdks/go.md
cp -v ../clients/elixir/README.md     docs/sdks/elixir.md

echo "Done."
