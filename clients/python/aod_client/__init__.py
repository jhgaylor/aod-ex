"""Agent on Demand — Python client.

    from aod_client import Client

    aod = Client(base_url="https://aod.example.com", token="...")

    agent = aod.agents.create(name="hello", runtime="claude",
                               model="anthropic/claude-sonnet-4-6")
    conv = aod.conversations.create(agent_id=agent["id"], prompt="Say hi.")

    final = aod.conversations.wait_for_result(conv["id"])
    print(final)

For live streaming use `aod.conversations.stream(conv_id)` which yields
parsed `Event` objects until the connection is closed.
"""

from .client import Client, Event, AodError

__all__ = ["Client", "Event", "AodError"]
__version__ = "0.1.0"
