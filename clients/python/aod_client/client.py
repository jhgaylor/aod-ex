"""Thin httpx-based AoD client.

Resource modules (agents/environments/conversations) hang off the
top-level `Client` and just call its `_request`. SSE streaming uses
`httpx.stream` and parses the wire format inline.
"""

from __future__ import annotations

import json
import os
import time
from dataclasses import dataclass
from typing import Any, Iterator, Optional

import httpx


class AodError(Exception):
    def __init__(self, status: int, body: Any):
        super().__init__(f"AoD API error {status}: {body!r}")
        self.status = status
        self.body = body


@dataclass
class Event:
    """One parsed SSE event from `/conversations/:id/stream`.

    `data` is the inner runtime stream-json line (already JSON-decoded
    if parseable, otherwise the raw string).
    """

    id: int
    kind: str          # "stage" | "output"
    stage: Optional[str]
    stream: Optional[str]
    state: Optional[str]
    data: Any


class Client:
    def __init__(
        self,
        base_url: Optional[str] = None,
        token: Optional[str] = None,
        timeout: float = 30.0,
    ):
        base_url = base_url or os.environ.get("AOD_BASE_URL", "http://localhost:4000")
        token = token or os.environ.get("AOD_TOKEN")
        if not token:
            raise ValueError("AOD_TOKEN not provided (arg or env var).")

        self.base_url = base_url.rstrip("/")
        self._http = httpx.Client(
            base_url=self.base_url + "/api",
            headers={"Authorization": f"Bearer {token}"},
            timeout=timeout,
        )
        self.token = token

        self.agents = _Agents(self)
        self.environments = _Environments(self)
        self.conversations = _Conversations(self)

    def close(self):
        self._http.close()

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()

    # ── internal ──────────────────────────────────────────────────

    def _request(self, method: str, path: str, json_body: Any = None) -> Any:
        resp = self._http.request(method, path, json=json_body)
        if resp.status_code >= 400:
            try:
                body: Any = resp.json()
            except Exception:
                body = resp.text
            raise AodError(resp.status_code, body)
        if resp.status_code == 204 or not resp.content:
            return None
        decoded = resp.json()
        return decoded.get("data") if isinstance(decoded, dict) else decoded


class _Agents:
    def __init__(self, client: Client):
        self._c = client

    def list(self) -> list[dict]:
        return self._c._request("GET", "/agents")

    def get(self, agent_id: str) -> dict:
        return self._c._request("GET", f"/agents/{agent_id}")

    def create(self, **fields) -> dict:
        return self._c._request("POST", "/agents", json_body=fields)

    def update(self, agent_id: str, **fields) -> dict:
        return self._c._request("PUT", f"/agents/{agent_id}", json_body=fields)

    def delete(self, agent_id: str) -> None:
        self._c._request("DELETE", f"/agents/{agent_id}")


class _Environments:
    def __init__(self, client: Client):
        self._c = client

    def list(self) -> list[dict]:
        return self._c._request("GET", "/environments")

    def get(self, env_id: str) -> dict:
        return self._c._request("GET", f"/environments/{env_id}")

    def create(self, **fields) -> dict:
        return self._c._request("POST", "/environments", json_body=fields)

    def update(self, env_id: str, **fields) -> dict:
        return self._c._request("PUT", f"/environments/{env_id}", json_body=fields)

    def delete(self, env_id: str) -> None:
        self._c._request("DELETE", f"/environments/{env_id}")

    def add_secret(self, env_id: str, key: str, value: str) -> dict:
        return self._c._request(
            "POST",
            f"/environments/{env_id}/secrets",
            json_body={"key": key, "value": value},
        )

    def remove_secret(self, env_id: str, key: str) -> None:
        self._c._request("DELETE", f"/environments/{env_id}/secrets/{key}")


class _Conversations:
    def __init__(self, client: Client):
        self._c = client

    def list(self) -> list[dict]:
        return self._c._request("GET", "/conversations")

    def get(self, conv_id: str) -> dict:
        return self._c._request("GET", f"/conversations/{conv_id}")

    def create(self, agent_id: str, prompt: str) -> dict:
        return self._c._request(
            "POST",
            "/conversations",
            json_body={"agent_id": agent_id, "prompt": prompt},
        )

    def prompt(self, conv_id: str, prompt: str) -> dict:
        return self._c._request(
            "POST",
            f"/conversations/{conv_id}/prompts",
            json_body={"prompt": prompt},
        )

    def interrupt(self, conv_id: str) -> dict:
        return self._c._request("POST", f"/conversations/{conv_id}/interrupt")

    def terminate(self, conv_id: str) -> dict:
        return self._c._request("POST", f"/conversations/{conv_id}/terminate")

    def delete(self, conv_id: str) -> None:
        self._c._request("DELETE", f"/conversations/{conv_id}")

    # ── streaming ─────────────────────────────────────────────────

    def stream(
        self,
        conv_id: str,
        *,
        streams: Optional[list[str]] = None,
        wait: bool = True,
        last_event_id: Optional[int] = None,
    ) -> Iterator[Event]:
        """Iterate SSE events for a conversation.

        - `streams`: filter to a subset of `stdout` / `stderr` / `stage`.
        - `wait`: when False, the server closes the stream after replay
          (no live tailing). Use this if you only want history.
        - `last_event_id`: resume from this event id forward.
        """
        params = {}
        if streams:
            params["streams"] = ",".join(streams)
        if not wait:
            params["wait"] = "false"

        headers = {}
        if last_event_id is not None:
            headers["Last-Event-ID"] = str(last_event_id)

        url = self._c.base_url + f"/api/conversations/{conv_id}/stream"
        with httpx.stream(
            "GET",
            url,
            params=params,
            headers={
                "Authorization": f"Bearer {self._c.token}",
                "Accept": "text/event-stream",
                **headers,
            },
            timeout=None,
        ) as resp:
            if resp.status_code >= 400:
                try:
                    body: Any = resp.read().decode()
                except Exception:
                    body = ""
                raise AodError(resp.status_code, body)

            yield from _parse_sse(resp.iter_lines())

    def wait_for_result(
        self,
        conv_id: str,
        *,
        poll_interval: float = 2.0,
        timeout: Optional[float] = None,
    ) -> Optional[str]:
        """Poll until the conversation leaves `running`/`pending`, then
        pull the runtime's terminal text out of the SSE replay.

        Returns `None` if no terminal text is found (e.g. failed turn).
        Currently implemented for the `claude` runtime; other runtimes
        return their last `:text` block via the same generic walk.
        """
        start = time.monotonic()
        while True:
            conv = self.get(conv_id)
            if conv["status"] not in ("running", "pending"):
                runtime = conv["runtime"]
                return _final_text(self.stream(conv_id, streams=["stdout"], wait=False), runtime)

            if timeout is not None and time.monotonic() - start > timeout:
                raise TimeoutError(f"Conversation {conv_id} still running after {timeout}s")

            time.sleep(poll_interval)


# ── SSE parsing ───────────────────────────────────────────────────


def _parse_sse(lines: Iterator[str]) -> Iterator[Event]:
    event_id: Optional[int] = None
    event_kind: str = "message"
    data_buf: list[str] = []

    for line in lines:
        if line == "":
            if data_buf:
                yield _make_event(event_id, event_kind, "".join(data_buf))
            event_id = None
            event_kind = "message"
            data_buf = []
            continue

        if line.startswith(":"):
            continue  # comment / heartbeat

        if line.startswith("id: "):
            try:
                event_id = int(line[4:])
            except ValueError:
                pass
        elif line.startswith("event: "):
            event_kind = line[7:]
        elif line.startswith("data: "):
            data_buf.append(line[6:])


def _make_event(event_id: Optional[int], kind: str, raw: str) -> Event:
    try:
        outer = json.loads(raw)
    except json.JSONDecodeError:
        return Event(event_id or 0, kind, None, None, None, raw)

    inner_raw = outer.get("data")
    if isinstance(inner_raw, str):
        try:
            inner = json.loads(inner_raw)
        except json.JSONDecodeError:
            inner = inner_raw
    else:
        inner = inner_raw

    return Event(
        id=event_id or 0,
        kind=outer.get("kind", kind),
        stage=outer.get("stage") or None,
        stream=outer.get("stream") or None,
        state=outer.get("state") or None,
        data=inner,
    )


def _final_text(events: Iterator[Event], runtime: str) -> Optional[str]:
    last_text: Optional[str] = None
    for ev in events:
        if ev.kind != "output" or not isinstance(ev.data, dict):
            continue

        if runtime == "claude" and ev.data.get("type") == "result":
            return ev.data.get("result")
        if (
            runtime == "codex"
            and ev.data.get("type") == "item.completed"
            and ev.data.get("item", {}).get("type") == "agent_message"
        ):
            last_text = ev.data["item"].get("text")
        if (
            runtime == "gemini"
            and ev.data.get("type") == "message"
            and ev.data.get("role") == "assistant"
        ):
            last_text = ev.data.get("content")
        if runtime == "opencode" and ev.data.get("type") == "text":
            text = ev.data.get("part", {}).get("text")
            if isinstance(text, str):
                last_text = (last_text or "") + text
    return last_text
