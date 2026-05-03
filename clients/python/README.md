# aod-client (Python)

Python client for the Agent on Demand API.

```bash
pip install httpx  # already a dep; no published package yet
```

## Quick start

```python
from aod_client import Client

with Client(base_url="https://aod.example.com", token="...") as aod:
    agent = next((a for a in aod.agents.list() if a["name"] == "echo-bot"))
    conv = aod.conversations.create(agent_id=agent["id"], prompt="Say hi")
    result = aod.conversations.wait_for_result(conv["id"])
    print(result)
```

`Client` reads `AOD_BASE_URL` (default `http://localhost:4000`) and `AOD_TOKEN` from the environment if you don't pass them in.

## Live streaming

```python
for ev in aod.conversations.stream(conv_id):
    if ev.kind == "stage":
        print(f"[{ev.stage}] {ev.state}")
    elif isinstance(ev.data, dict) and ev.data.get("type") == "result":
        print("FINAL:", ev.data.get("result"))
        break
```

`stream()` accepts `streams=["stdout"]` to filter, `wait=False` to drain the replay only, and `last_event_id=N` to resume.

## Resources

- `aod.agents.{list, get, create, update, delete}`
- `aod.environments.{list, get, create, update, delete, add_secret, remove_secret}`
- `aod.conversations.{list, get, create, prompt, interrupt, terminate, delete, stream, wait_for_result}`

All methods raise `AodError(status, body)` on non-2xx responses.
