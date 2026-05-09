// Agent on Demand — TypeScript client.
//
//   import { Client } from "@aod/client";
//
//   const aod = new Client({
//     baseUrl: "https://aod.example.com",
//     token: process.env.AOD_TOKEN!,
//   });
//
//   const agent = (await aod.agents.list()).find(a => a.name === "echo-bot")!;
//   const conv = await aod.conversations.create({ agent_id: agent.id, prompt: "Say hi" });
//   const result = await aod.conversations.waitForResult(conv.id);
//   console.log(result);
//
// Live streaming uses an async generator over the SSE stream.

export interface ClientOpts {
  baseUrl?: string;
  token: string;
  fetch?: typeof fetch;
}

export interface AodEvent {
  id: number;
  kind: string;        // "stage" | "output"
  stage: string | null;
  stream: string | null;
  state: string | null;
  data: unknown;
}

export class AodError extends Error {
  constructor(public status: number, public body: unknown) {
    super(`AoD API error ${status}: ${JSON.stringify(body)}`);
    this.name = "AodError";
  }
}

export class Client {
  readonly baseUrl: string;
  readonly token: string;
  readonly agents: AgentsResource;
  readonly environments: EnvironmentsResource;
  readonly conversations: ConversationsResource;

  private readonly _fetch: typeof fetch;

  constructor(opts: ClientOpts) {
    this.baseUrl = (opts.baseUrl ?? envBaseUrl() ?? "http://localhost:4000")
      .replace(/\/+$/, "");
    this.token = opts.token;
    this._fetch = opts.fetch ?? fetch;
    this.agents = new AgentsResource(this);
    this.environments = new EnvironmentsResource(this);
    this.conversations = new ConversationsResource(this);
  }

  async _request<T = unknown>(method: string, path: string, body?: unknown): Promise<T> {
    const resp = await this._fetch(`${this.baseUrl}/api${path}`, {
      method,
      headers: {
        Authorization: `Bearer ${this.token}`,
        ...(body !== undefined ? { "Content-Type": "application/json" } : {}),
      },
      body: body !== undefined ? JSON.stringify(body) : undefined,
    });
    if (!resp.ok) {
      let parsed: unknown;
      try { parsed = await resp.json(); } catch { parsed = await resp.text(); }
      throw new AodError(resp.status, parsed);
    }
    if (resp.status === 204) return undefined as T;
    const decoded = await resp.json();
    return (decoded && typeof decoded === "object" && "data" in decoded ? decoded.data : decoded) as T;
  }
}

class AgentsResource {
  constructor(private c: Client) {}
  list = () => this.c._request<any[]>("GET", "/agents");
  get = (id: string) => this.c._request<any>("GET", `/agents/${id}`);
  create = (fields: Record<string, unknown>) => this.c._request<any>("POST", "/agents", fields);
  update = (id: string, fields: Record<string, unknown>) =>
    this.c._request<any>("PUT", `/agents/${id}`, fields);
  delete = (id: string) => this.c._request<void>("DELETE", `/agents/${id}`);
}

class EnvironmentsResource {
  constructor(private c: Client) {}
  list = () => this.c._request<any[]>("GET", "/environments");
  get = (id: string) => this.c._request<any>("GET", `/environments/${id}`);
  create = (fields: Record<string, unknown>) => this.c._request<any>("POST", "/environments", fields);
  update = (id: string, fields: Record<string, unknown>) =>
    this.c._request<any>("PUT", `/environments/${id}`, fields);
  delete = (id: string) => this.c._request<void>("DELETE", `/environments/${id}`);
  addSecret = (id: string, key: string, value: string) =>
    this.c._request<any>("POST", `/environments/${id}/secrets`, { key, value });
  removeSecret = (id: string, key: string) =>
    this.c._request<void>("DELETE", `/environments/${id}/secrets/${key}`);
}

export interface ImageInput {
  /** Raw image bytes or base64-encoded string. */
  data: Uint8Array | string;
  media_type: "image/png" | "image/jpeg" | "image/gif" | "image/webp";
}

interface ConversationCreate {
  agent_id: string;
  prompt: string;
  images?: ImageInput[];
}

interface StreamOpts {
  streams?: ("stdout" | "stderr" | "stage")[];
  wait?: boolean;
  lastEventId?: number;
  signal?: AbortSignal;
}

class ConversationsResource {
  constructor(private c: Client) {}

  list = () => this.c._request<any[]>("GET", "/conversations");
  get = (id: string) => this.c._request<any>("GET", `/conversations/${id}`);

  create = (req: ConversationCreate) => {
    const body: any = { ...req };
    if (req.images?.length) body.images = encodeImages(req.images);
    return this.c._request<any>("POST", "/conversations", body);
  };

  prompt = (id: string, prompt: string, images?: ImageInput[]) => {
    const body: any = { prompt };
    if (images?.length) body.images = encodeImages(images);
    return this.c._request<any>("POST", `/conversations/${id}/prompts`, body);
  };
  interrupt = (id: string) => this.c._request<any>("POST", `/conversations/${id}/interrupt`);
  terminate = (id: string) => this.c._request<any>("POST", `/conversations/${id}/terminate`);
  delete = (id: string) => this.c._request<void>("DELETE", `/conversations/${id}`);

  /** Async iterator over SSE events for a conversation. */
  async *stream(convId: string, opts: StreamOpts = {}): AsyncIterableIterator<AodEvent> {
    const params = new URLSearchParams();
    if (opts.streams?.length) params.set("streams", opts.streams.join(","));
    if (opts.wait === false) params.set("wait", "false");

    const headers: Record<string, string> = {
      Authorization: `Bearer ${this.c.token}`,
      Accept: "text/event-stream",
    };
    if (opts.lastEventId !== undefined) {
      headers["Last-Event-ID"] = String(opts.lastEventId);
    }

    const url = `${this.c.baseUrl}/api/conversations/${convId}/stream?${params}`;
    const resp = await fetch(url, { headers, signal: opts.signal });
    if (!resp.ok) {
      throw new AodError(resp.status, await resp.text());
    }
    if (!resp.body) return;

    const reader = resp.body.getReader();
    const decoder = new TextDecoder();
    let buf = "";

    try {
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        buf += decoder.decode(value, { stream: true });

        let sep: number;
        // SSE messages are delimited by blank line ("\n\n").
        while ((sep = buf.indexOf("\n\n")) !== -1) {
          const block = buf.slice(0, sep);
          buf = buf.slice(sep + 2);
          const event = parseSSEBlock(block);
          if (event) yield event;
        }
      }
    } finally {
      reader.releaseLock();
    }
  }

  /** Poll until the conversation leaves running/pending, then drain
   *  the SSE replay and return the runtime's terminal text. */
  async waitForResult(
    convId: string,
    opts: { pollIntervalMs?: number; timeoutMs?: number } = {},
  ): Promise<string | null> {
    const interval = opts.pollIntervalMs ?? 2000;
    const start = Date.now();

    for (;;) {
      const conv = await this.get(convId);
      if (conv.status !== "running" && conv.status !== "pending") {
        return finalText(this.stream(convId, { streams: ["stdout"], wait: false }), conv.runtime);
      }
      if (opts.timeoutMs && Date.now() - start > opts.timeoutMs) {
        throw new Error(`Conversation ${convId} still running after ${opts.timeoutMs}ms`);
      }
      await new Promise((r) => setTimeout(r, interval));
    }
  }
}

function encodeImages(images: ImageInput[]): { data: string; media_type: string }[] {
  return images.map((img) => {
    let data: string;
    if (typeof img.data === "string") {
      data = img.data;
    } else {
      // Encode Uint8Array to base64
      let binary = "";
      for (let i = 0; i < img.data.length; i++) {
        binary += String.fromCharCode(img.data[i]);
      }
      data = btoa(binary);
    }
    return { data, media_type: img.media_type };
  });
}

function parseSSEBlock(block: string): AodEvent | null {
  let id: number | null = null;
  let kind = "message";
  const dataLines: string[] = [];

  for (const line of block.split("\n")) {
    if (line.startsWith(":")) continue;
    if (line.startsWith("id: ")) {
      const n = Number(line.slice(4));
      if (Number.isFinite(n)) id = n;
    } else if (line.startsWith("event: ")) {
      kind = line.slice(7);
    } else if (line.startsWith("data: ")) {
      dataLines.push(line.slice(6));
    }
  }

  if (dataLines.length === 0) return null;

  let outer: any;
  try { outer = JSON.parse(dataLines.join("")); } catch { return null; }

  let data: unknown = outer.data;
  if (typeof data === "string") {
    try { data = JSON.parse(data); } catch { /* leave as-is */ }
  }

  return {
    id: id ?? 0,
    kind: outer.kind ?? kind,
    stage: outer.stage || null,
    stream: outer.stream || null,
    state: outer.state || null,
    data,
  };
}

// `process.env` is Node-only; in a browser bundle it's undefined. Read
// it through a type-guarded helper so the SDK builds cleanly without
// `@types/node` and degrades to "no env fallback" in the browser.
function envBaseUrl(): string | undefined {
  const proc: any = (globalThis as any).process;
  return proc?.env?.AOD_BASE_URL;
}

async function finalText(
  events: AsyncIterableIterator<AodEvent>,
  runtime: string,
): Promise<string | null> {
  let last: string | null = null;
  for await (const ev of events) {
    if (ev.kind !== "output" || !ev.data || typeof ev.data !== "object") continue;
    const d = ev.data as any;

    if (runtime === "claude" && d.type === "result") return d.result ?? null;
    if (
      runtime === "codex" &&
      d.type === "item.completed" &&
      d.item?.type === "agent_message"
    ) {
      last = d.item.text ?? last;
    }
    if (runtime === "gemini" && d.type === "message" && d.role === "assistant") {
      last = d.content ?? last;
    }
    if (runtime === "opencode" && d.type === "text" && typeof d.part?.text === "string") {
      last = (last ?? "") + d.part.text;
    }
  }
  return last;
}
