# AoD client SDKs

Hand-written, idiomatic clients for the Agent on Demand API. Each one is intentionally thin — the API is small (14 paths, mostly CRUD) and the only differentiating piece is the SSE `/stream` endpoint, which generated SDKs don't model well.

| Language | Path | Runtime dep | Status |
| --- | --- | --- | --- |
| Python | [`python/`](./python) | `httpx` | manual install (no published package yet) |
| TypeScript | [`typescript/`](./typescript) | none (`fetch`) | manual install (no published package yet) |
| Go | [`go/`](./go) | stdlib only | `go get github.com/ravi-hq/agent-on-demand-ex/clients/go/aod` |
| Elixir | [`elixir/`](./elixir) | `req` + `jason` | manual `path:` dep |

All four follow the same shape:

- `Client` constructor reads `base_url` + `token` from arg or env (`AOD_BASE_URL`, `AOD_TOKEN`).
- Three resource namespaces: `agents`, `environments`, `conversations`.
- `conversations.stream(id)` returns an iterator/async-iterator/channel/Stream of parsed `Event` records (one per SSE message; the inner runtime stream-json is decoded for you).
- `conversations.wait_for_result(id)` polls status, then drains the SSE replay and pulls out the runtime's terminal text (handles claude / codex / gemini / opencode shapes).

If you're writing one in a fifth language, the contract is small enough to follow the existing implementations — there's a section in the [API help topic](../priv/help/api.md) listing every path and schema. The full OpenAPI spec also lives at `/api/openapi.json` on any running instance, but generators are overkill for this surface.
