# Deploying AoD to a Sprite

`mix aod.up` provisions a Sprite, pushes a Burrito-wrapped binary into it, registers the binary as a Sprites-managed service, and prints the public URL + admin token.

```bash
$ SPRITES_TOKEN=... mix aod.up
→ provisioning sprite 'aod-1777682103'...
→ flipping URL auth to public...
→ pushing binary (21.4 MB) to sprite...
→ writing /opt/aod/start.sh wrapper...
→ registering service via sprite-env (survives hibernation)...
→ polling /health (will auto-start service on first hit)...
→ /health 200 OK after 1 tries.

  URL:         https://aod-1777682103-bagzz.sprites.app
  ADMIN_TOKEN: 2e9b98d538fcf4297dd12ff0faf64dd36b36d12a6351023f
```

The Sprite-side service (`sprite-env services create aod --http-port 4000`) survives hibernation and auto-starts on incoming HTTP requests — first request after idle pays a 100–500 ms warm-up.

## Prerequisites

- **`SPRITES_TOKEN`** in env or `.env`.
- A linux binary. `aod up` looks in two places, in order:
  1. **Local build** at `burrito_out/aod_linux` — produced by `MIX_ENV=prod mix release` (requires Zig 0.15.2; see below). Used if it exists. Skip the local build if you don't need it.
  2. **GitHub release** matching the build's version (`v0.1.0`) — downloaded automatically and cached at `~/.cache/aod/releases/<tag>/` (or `$XDG_CACHE_HOME/aod/...`). Override with `--release vX.Y.Z`.

### Building locally (optional)

Only needed if you want to push a binary you've built from your working tree (e.g. testing an unreleased change). For released versions, the automatic GitHub-release download is faster and doesn't need Zig at all.

- **Zig 0.15.2** — `brew` ships 0.16; install 0.15.2 manually:
  ```bash
  curl -L https://ziglang.org/download/0.15.2/zig-aarch64-macos-0.15.2.tar.xz \
    | tar -xJ -C ~/.local && mv ~/.local/zig-aarch64-macos-0.15.2 ~/.local/zig-0.15.2
  export PATH="$HOME/.local/zig-0.15.2:$PATH"
  ```
- `MIX_ENV=prod mix release` — produces `burrito_out/aod_linux` and `burrito_out/aod_macos`.

## Releases (CI-built)

Tag-push to `v*.*.*` triggers `.github/workflows/release.yml`, which builds both `aod-linux-x86_64` and `aod-macos-aarch64` and uploads them as GitHub release assets. Operators can:

- `mix aod.up` to deploy/upgrade — fetches the linux binary itself.
- `curl -L https://github.com/jhgaylor/aod-ex/releases/download/<tag>/aod-macos-aarch64 > aod && chmod +x aod` to use the dual-mode binary as a CLI on macOS without Erlang installed.

## What it does

1. `Sprites.create` — provisions a fresh microVM, gets back a `*.sprites.app` URL.
2. `Sprites.update_url_settings(%{auth: "public"})` — flips the URL from bearer-tokened to publicly reachable; AoD's own `ADMIN_TOKEN` is the auth layer at the app level.
3. `Sprites.Filesystem.write` — pushes the 21 MB Burrito binary to `/opt/aod/aod`. Binary push dominates first-deploy time (~10 s).
4. Writes `/opt/aod/start.sh` — a tiny wrapper that exports env vars (PHX_HOST, ADMIN_TOKEN, SECRETS_KEY, etc.) and execs the binary.
5. `sprite-env services create aod --http-port 4000` — registers the service so it survives hibernation and so the public URL routes to port 4000.
6. Polls `/health` — first request auto-starts the service.

## Upgrade in place

Re-run with the same `--name` to swap the binary on an existing deployment without losing state:

```bash
SPRITES_TOKEN=... mix aod.up --name <existing-name>                    # latest local or release
SPRITES_TOKEN=... mix aod.up --name <existing-name> --release v0.2.0   # specific release
```

The DB at `/opt/aod/data/aod.db` and the encryption keys are recovered from `start.sh` so existing data survives.

## Tear-down

```bash
mix aod.down <sprite-name>
```

Destroys the entire Sprite.

---

## Burrito debt — one remaining workaround

The cross-build path needs **one custom Burrito step** in `lib/aod/burrito/`.

### The root cause

Burrito ships precompiled ERTS for select OTP versions via [beam-machine](https://beam-machine-universal.b-cdn.net). We snapshotted those tarballs into a `vendor-erts-otp-28.4` GitHub release on this repo and pin `custom_erts:` at our own URLs — beam-machine's URLs are not immutable (in v0.2.11 the upstream republished an OTP build with `_FORTIFY_SOURCE` enabled, which tripped `__memcpy_chk` symbol resolution under musl and broke deploys). Pointing at our own release fixes drift; see the release notes for the snapshotted SHAs. To bump OTP, snapshot a verified tarball into a new `vendor-erts-*` release and update `mix.exs`. Pinning at a `custom_erts: <url>` then triggers one Burrito issue:

**`Burrito.Steps.Fetch.FetchMusl` skips us.** It pattern-matches on `erts_source: {:precompiled, _}`. With `custom_erts: <url>`, the source becomes `{:url, _}` — FetchMusl never runs, so `__BURRITO_MUSL_RUNTIME_PATH` stays empty and the wrapper compiles without the dynamic linker. beam.smp then fails at runtime with `error: FileNotFound`.

### The workaround

- **`lib/aod/burrito/inject_musl_path.ex`** — replicates `FetchMusl`'s download + env-var injection, unconditionally. Wired as a `fetch:pre` step.

### How to retire it

`InjectMuslPath` can be removed when Burrito upstream handles `:url` source the same as `:precompiled` for musl runtime install.

### Build prerequisites

The repo includes a `.tool-versions` at the root pinning `erlang 28.4` and `elixir 1.19.5-otp-28`. Use [asdf](https://asdf-vm.com) (or [mise](https://mise.jdx.dev), which also reads `.tool-versions`) to install the correct versions before building releases locally. This keeps local OTP aligned with the `custom_erts` target and prevents NIF version mismatches.

### One more thing

The Burrito **install cache** at `~/Library/Application Support/.burrito/<app>_erts-<v>_<app_version>` is keyed by app version. Iterating without bumping `version` in `mix.exs` means the wrapper reuses an old cached extract — including stale `.beam`s. If you change code and the running release shows the old behavior, blow away that cache dir.

---

## Render deploy (alternative)

For a hosted-but-not-Sprites deploy, `render.yaml` is still wired up. See the README's "Production deploy (Render)" section.
