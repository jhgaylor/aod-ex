# @aod/client (TypeScript)

TypeScript client for the Agent on Demand API. Zero runtime deps — just `fetch`.

```bash
npm install @aod/client  # not published yet; consume from this folder for now
```

## Quick start

```ts
import { Client } from "@aod/client";

const aod = new Client({ baseUrl: "https://aod.example.com", token: process.env.AOD_TOKEN! });

const agent = (await aod.agents.list()).find(a => a.name === "echo-bot")!;
const conv = await aod.conversations.create({ agent_id: agent.id, prompt: "Say hi" });
const result = await aod.conversations.waitForResult(conv.id);
console.log(result);
```

`AOD_BASE_URL` env var is the default for `baseUrl` when running under Node.

## Live streaming

```ts
for await (const ev of aod.conversations.stream(convId)) {
  if (ev.kind === "stage") {
    console.log(`[${ev.stage}] ${ev.state}`);
  } else if (typeof ev.data === "object" && (ev.data as any)?.type === "result") {
    console.log("FINAL:", (ev.data as any).result);
    break;
  }
}
```

`stream()` accepts:
- `streams: ["stdout"]` to filter
- `wait: false` to drain replay only and close
- `lastEventId: N` to resume
- `signal: AbortSignal` to cancel

## Resources

- `aod.agents.{list, get, create, update, delete}`
- `aod.environments.{list, get, create, update, delete, addSecret, removeSecret}`
- `aod.conversations.{list, get, create, prompt, interrupt, terminate, delete, stream, waitForResult}`

All methods throw `AodError(status, body)` on non-2xx responses.

## Build

```bash
npm run build
```
