# aod_client (Elixir)

Elixir client for the Agent on Demand API. Built on `Req`.

```elixir
{:aod_client, path: "../path/to/clients/elixir"}
```

## Quick start

```elixir
client = AodClient.new(base_url: "https://aod.example.com",
                       token: System.get_env("AOD_TOKEN"))

{:ok, agents} = AodClient.Agents.list(client)
agent         = Enum.find(agents, & &1["name"] == "echo-bot")

{:ok, conv}   = AodClient.Conversations.create(client,
                  agent_id: agent["id"], prompt: "Say hi")

{:ok, text}   = AodClient.Conversations.wait_for_result(client, conv["id"])
IO.puts(text)
```

`base_url` and `token` fall back to the `AOD_BASE_URL` and `AOD_TOKEN` env vars.

## Live streaming

```elixir
client
|> AodClient.Conversations.stream(conv["id"])
|> Enum.each(fn ev ->
  case ev do
    %{kind: "stage", stage: stage, state: state} ->
      IO.puts("[#{stage}] #{state}")
    %{data: %{"type" => "result", "result" => text}} ->
      IO.puts("FINAL: #{text}")
    _ ->
      :ok
  end
end)
```

`stream/3` accepts:
- `streams: ["stdout"]` — comma-separated allow-list
- `wait: false` — drain replay only
- `last_event_id: N` — resume

## Resources

- `AodClient.Agents.{list, get, create, update, delete}/1,2,3`
- `AodClient.Environments.{list, get, create, update, delete, add_secret, remove_secret}/1,2,3,4`
- `AodClient.Conversations.{list, get, create, prompt, interrupt, terminate, delete, stream, wait_for_result}/1,2,3`

All non-stream calls return `{:ok, body}` or `{:error, reason}`.
