defmodule AodClient.Conversations do
  @moduledoc """
  CRUD + SSE streaming for conversations.
  """

  alias AodClient.Api

  def list(client), do: Api.get(client, "/conversations")
  def get(client, id), do: Api.get(client, "/conversations/#{id}")

  def create(client, fields, images \\ []) do
    fields = Map.new(fields)
    body = if images != [], do: Map.put(fields, :images, encode_images(images)), else: fields
    Api.post(client, "/conversations", body)
  end

  @doc """
  Send a prompt to an existing conversation.

  `images` is an optional list of `%{data: binary, media_type: string}` maps.
  The `data` field should be raw bytes; this function handles base64 encoding.
  """
  def prompt(client, id, prompt, images \\ []) do
    body = %{prompt: prompt}
    body = if images != [], do: Map.put(body, :images, encode_images(images)), else: body
    Api.post(client, "/conversations/#{id}/prompts", body)
  end

  defp encode_images(images) do
    Enum.map(images, fn %{data: data, media_type: mt} ->
      %{data: Base.encode64(data), media_type: mt}
    end)
  end

  def interrupt(client, id), do: Api.post(client, "/conversations/#{id}/interrupt")
  def terminate(client, id), do: Api.post(client, "/conversations/#{id}/terminate")
  def delete(client, id), do: Api.delete(client, "/conversations/#{id}")

  @doc """
  Lazy `Stream` of parsed SSE events for a conversation.

  Options:

    * `:streams` — list of `"stdout"`, `"stderr"`, `"stage"` to filter to.
    * `:wait` — when `false`, the server closes after replay (no live tail).
    * `:last_event_id` — resume from this id forward.

  Each emitted event is a map: `%{id, kind, stage, stream, state, data}`
  where `data` is the inner runtime stream-json line (decoded when
  parseable, otherwise the raw string).
  """
  def stream(client, conv_id, opts \\ []) do
    Stream.resource(
      fn -> open_stream(client, conv_id, opts) end,
      &read_chunk/1,
      &close_stream/1
    )
    |> Stream.flat_map(& &1)
  end

  @doc """
  Block until the conversation leaves `running`/`pending`, then drain
  the SSE replay and return the runtime's terminal text.

  Returns `{:ok, text}` on success, `{:error, reason}` otherwise.
  `text` is `nil` if no terminal text is found (e.g. failed turn).
  """
  def wait_for_result(client, conv_id, opts \\ []) do
    poll = Keyword.get(opts, :poll_ms, 2_000)
    deadline = Keyword.get(opts, :timeout_ms) && System.monotonic_time(:millisecond) + opts[:timeout_ms]

    do_wait(client, conv_id, poll, deadline)
  end

  defp do_wait(client, conv_id, poll, deadline) do
    case get(client, conv_id) do
      {:ok, %{"status" => s}} when s in ["running", "pending"] ->
        if deadline && System.monotonic_time(:millisecond) > deadline do
          {:error, :timeout}
        else
          Process.sleep(poll)
          do_wait(client, conv_id, poll, deadline)
        end

      {:ok, %{"runtime" => runtime}} ->
        text =
          stream(client, conv_id, streams: ["stdout"], wait: false)
          |> final_text(runtime)

        {:ok, text}

      err ->
        err
    end
  end

  # ── SSE plumbing ──────────────────────────────────────────────────

  defp open_stream(client, conv_id, opts) do
    qs =
      [{"streams", opts[:streams] && Enum.join(opts[:streams], ",")},
       {"wait", opts[:wait] == false && "false"}]
      |> Enum.reject(fn {_, v} -> is_nil(v) or v == false end)
      |> URI.encode_query()

    headers =
      [{"accept", "text/event-stream"}]
      |> then(fn h ->
        case opts[:last_event_id] do
          nil -> h
          id -> [{"last-event-id", to_string(id)} | h]
        end
      end)

    url = client.base_url <> "/api/conversations/#{conv_id}/stream" <> if(qs == "", do: "", else: "?" <> qs)

    {:ok, resp} =
      Req.get(client.req,
        url: url,
        headers: headers,
        receive_timeout: :infinity,
        into: :self
      )

    %{resp: resp, buf: ""}
  end

  defp read_chunk(state) do
    case Req.parse_message(state.resp, receive_chunk(state.resp)) do
      {:ok, [{:data, chunk}]} ->
        {events, buf} = consume(state.buf <> chunk)
        {events, %{state | buf: buf}}

      {:ok, [:done]} ->
        {:halt, state}

      {:ok, []} ->
        {[], state}

      {:error, _} ->
        {:halt, state}
    end
  end

  defp receive_chunk(resp) do
    receive do
      msg when elem(msg, 0) == resp.async.ref -> msg
    after
      60_000 -> :timeout
    end
  end

  defp consume(buf) do
    case String.split(buf, "\n\n", parts: 2) do
      [block, rest] ->
        events =
          case parse_block(block) do
            nil -> []
            ev -> [ev]
          end

        {more_events, final_buf} = consume(rest)
        {events ++ more_events, final_buf}

      [partial] ->
        {[], partial}
    end
  end

  defp parse_block(block) do
    {id, kind, data} =
      block
      |> String.split("\n", trim: true)
      |> Enum.reduce({nil, "message", []}, fn line, {id, kind, data} ->
        cond do
          String.starts_with?(line, ":") -> {id, kind, data}
          String.starts_with?(line, "id: ") -> {parse_int(String.slice(line, 4..-1//1)), kind, data}
          String.starts_with?(line, "event: ") -> {id, String.slice(line, 7..-1//1), data}
          String.starts_with?(line, "data: ") -> {id, kind, [String.slice(line, 6..-1//1) | data]}
          true -> {id, kind, data}
        end
      end)

    case data do
      [] ->
        nil

      _ ->
        raw = data |> Enum.reverse() |> Enum.join("")

        with {:ok, outer} <- Jason.decode(raw) do
          inner =
            case outer["data"] do
              s when is_binary(s) -> case Jason.decode(s) do
                                       {:ok, v} -> v
                                       _ -> s
                                     end
              other -> other
            end

          %{
            id: id || 0,
            kind: outer["kind"] || kind,
            stage: outer["stage"],
            stream: outer["stream"],
            state: outer["state"],
            data: inner
          }
        else
          _ -> nil
        end
    end
  end

  defp parse_int(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp close_stream(%{resp: resp}) do
    if resp.async, do: Req.cancel_async_response(resp), else: :ok
  end

  defp final_text(events, runtime) do
    Enum.reduce_while(events, nil, fn ev, last ->
      case {ev[:kind], ev[:data]} do
        {"output", %{"type" => "result"}} when runtime == "claude" ->
          {:halt, ev.data["result"]}

        {"output", %{"type" => "item.completed", "item" => %{"type" => "agent_message", "text" => t}}}
        when runtime == "codex" ->
          {:cont, t}

        {"output", %{"type" => "message", "role" => "assistant", "content" => t}}
        when runtime == "gemini" ->
          {:cont, t}

        {"output", %{"type" => "text", "part" => %{"text" => t}}}
        when runtime == "opencode" ->
          {:cont, (last || "") <> t}

        _ ->
          {:cont, last}
      end
    end)
  end
end
