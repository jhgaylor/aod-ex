# aod (Go)

Go client for the Agent on Demand API. Stdlib-only — no external deps.

```bash
go get github.com/jhgaylor/aod-ex/clients/go/aod
```

## Quick start

```go
ctx := context.Background()
c, _ := aod.New(aod.Config{
    BaseURL: "https://aod.example.com",
    Token:   os.Getenv("AOD_TOKEN"),
})

agents, _ := c.Agents.List(ctx)
var agent aod.Agent
for _, a := range agents {
    if a.Name == "echo-bot" { agent = a; break }
}

conv, _ := c.Conversations.Create(ctx, aod.ConversationCreate{
    AgentID: agent.ID, Prompt: "Say hi",
})

result, _ := c.Conversations.WaitForResult(ctx, conv.ID)
fmt.Println(result)
```

`AOD_BASE_URL` is the env-var fallback for `BaseURL` if not set in `Config`.

## Live streaming

```go
wait := true
ch, err := c.Conversations.Stream(ctx, conv.ID, aod.StreamOpts{
    Streams: []string{"stdout"},
    Wait:    &wait,
})
if err != nil { log.Fatal(err) }

for ev := range ch {
    if d, ok := ev.Data.(map[string]any); ok && d["type"] == "result" {
        fmt.Println("FINAL:", d["result"])
        cancel()
    }
}
```

`StreamOpts.Wait = &wait` (with `wait := false`) drains the replay and closes immediately. `LastEventID` resumes from a known id.

## Resources

- `c.Agents.{List, Get, Create, Update, Delete}`
- `c.Environments.{List, Get, Create, Update, Delete, AddSecret, RemoveSecret}`
- `c.Conversations.{List, Get, Create, Prompt, Interrupt, Terminate, Delete, Stream, WaitForResult}`

All methods take `context.Context` and return `*aod.Error` on non-2xx (the error wraps `Status` and raw `Body`).
