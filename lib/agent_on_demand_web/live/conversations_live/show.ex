defmodule AgentOnDemandWeb.ConversationsLive.Show do
  use AgentOnDemandWeb, :live_view

  alias AgentOnDemand.Conversations
  alias AgentOnDemand.Conversations.{ConversationServer, LogEvent}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Conversations.get_conversation(id) do
      nil ->
        {:ok, socket |> put_flash(:error, "Conversation not found") |> push_navigate(to: ~p"/")}

      conv ->
        if connected?(socket) do
          Phoenix.PubSub.subscribe(AgentOnDemand.PubSub, "conv:#{id}")
        end

        events = Conversations.list_log_events(id)

        {:ok,
         socket
         |> assign(:page_title, "Conversation #{binary_part(id, 0, 8)}")
         |> assign(:conv, conv)
         |> assign(:events, events)
         |> assign(:streams, MapSet.new(["stdout", "stderr", "stage"]))
         |> assign(:prompt, "")}
    end
  end

  @impl true
  def handle_info({:log_event, %LogEvent{} = ev}, socket) do
    if ev.id > last_event_id(socket.assigns.events) do
      {:noreply, assign(socket, :events, socket.assigns.events ++ [ev])}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("send_prompt", %{"prompt" => p}, socket) when byte_size(p) > 0 do
    case ConversationServer.send_prompt(socket.assigns.conv.id, p) do
      :ok ->
        # Refetch the conversation — wake-from-cold flips sandbox + status.
        conv = Conversations.get_conversation!(socket.assigns.conv.id)

        {:noreply,
         socket
         |> assign(:conv, conv)
         |> assign(:prompt, "")
         |> put_flash(:info, "Queued")}

      {:error, :busy} ->
        {:noreply, put_flash(socket, :error, "A turn is already running")}

      {:error, :gone} ->
        {:noreply, put_flash(socket, :error, "Conversation is terminated and can't be resumed")}

      {:error, :not_running} ->
        {:noreply, put_flash(socket, :error, "Conversation is no longer running")}

      {:error, :no_agent} ->
        {:noreply, put_flash(socket, :error, "Conversation has no agent — can't resume")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Couldn't send: #{inspect(reason)}")}
    end
  end

  def handle_event("send_prompt", _, socket), do: {:noreply, socket}

  def handle_event("terminate", _, socket) do
    case ConversationServer.terminate(socket.assigns.conv.id) do
      :ok ->
        conv = Conversations.get_conversation!(socket.assigns.conv.id)
        {:noreply, socket |> assign(:conv, conv) |> put_flash(:info, "Terminated")}

      _ ->
        {:noreply, put_flash(socket, :error, "Not running")}
    end
  end

  def handle_event("interrupt", _, socket) do
    case ConversationServer.interrupt(socket.assigns.conv.id) do
      :ok ->
        conv = Conversations.get_conversation!(socket.assigns.conv.id)
        {:noreply, socket |> assign(:conv, conv) |> put_flash(:info, "Interrupted")}

      {:error, :idle} ->
        {:noreply, put_flash(socket, :error, "No turn is running")}

      {:error, :not_running} ->
        {:noreply, put_flash(socket, :error, "Conversation is no longer running")}
    end
  end

  def handle_event("delete", _, socket) do
    {:ok, _} = Conversations.delete_conversation(socket.assigns.conv)

    {:noreply,
     socket
     |> put_flash(:info, "Conversation deleted")
     |> push_navigate(to: ~p"/")}
  end

  def handle_event("update_prompt", %{"prompt" => p}, socket) do
    {:noreply, assign(socket, :prompt, p)}
  end

  # Toggle a stream filter pill on/off. Defaults to all three on.
  def handle_event("toggle_stream", %{"stream" => name}, socket) do
    streams =
      if MapSet.member?(socket.assigns.streams, name) do
        MapSet.delete(socket.assigns.streams, name)
      else
        MapSet.put(socket.assigns.streams, name)
      end

    {:noreply, assign(socket, :streams, streams)}
  end

  defp event_visible?(%{kind: "stage"}, streams), do: MapSet.member?(streams, "stage")

  defp event_visible?(%{kind: "output", stream: s}, streams) when is_binary(s),
    do: MapSet.member?(streams, s)

  defp event_visible?(_ev, _streams), do: false

  defp last_event_id([]), do: 0
  defp last_event_id(events), do: events |> List.last() |> Map.get(:id, 0)

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-4">
      <div class="flex items-center justify-between">
        <div>
          <div class="text-sm text-zinc-500 font-mono">{@conv.id}</div>
          <div class="text-2xl font-semibold flex items-center gap-3">
            Conversation
            <.status_badge status={@conv.status} />
          </div>
          <div class="text-sm text-zinc-500">runtime: {@conv.runtime}</div>
          <div :if={@conv.sandbox} class="text-sm text-zinc-500 font-mono">
            sprite: {@conv.sandbox.sprite_name}
            <span class="text-zinc-400">({String.slice(@conv.sandbox.id, 0, 8)} · {@conv.sandbox.status})</span>
          </div>
        </div>
        <div class="flex gap-2">
          <.btn_secondary :if={@conv.status == "running"}
            phx-click="interrupt" data-confirm="Stop the running turn?">
            Interrupt
          </.btn_secondary>
          <.btn_danger :if={@conv.status not in ["terminated", "completed", "failed"]}
            phx-click="terminate" data-confirm="Terminate this conversation?">
            Terminate
          </.btn_danger>
          <.btn_secondary phx-click="delete"
            data-confirm="Delete this conversation and all its turns? This cannot be undone.">
            Delete
          </.btn_secondary>
        </div>
      </div>

      <div class="flex items-center gap-2 text-xs">
        <span class="text-zinc-500">show:</span>
        <.stream_pill name="stage" label="stage" active={MapSet.member?(@streams, "stage")} />
        <.stream_pill name="stdout" label="stdout" active={MapSet.member?(@streams, "stdout")} />
        <.stream_pill name="stderr" label="stderr" active={MapSet.member?(@streams, "stderr")} />
      </div>

      <div class="bg-zinc-900 text-zinc-100 rounded shadow p-4 h-[60vh] overflow-y-auto font-mono text-xs space-y-1"
        id="log-stream" phx-hook="ScrollBottom">
        <%= for ev <- @events, event_visible?(ev, @streams) do %>
          <.event_line event={ev}/>
        <% end %>
        <div :if={@events == []} class="text-zinc-500">Waiting for output…</div>
      </div>

      <form phx-submit="send_prompt" phx-change="update_prompt" class="bg-white rounded shadow border border-zinc-200 p-4 space-y-3">
        <.input id="prompt" name="prompt" type="textarea" rows="3"
          value={@prompt} placeholder="Send another prompt…"/>
        <div class="flex justify-end gap-2">
          <.btn type="submit" phx-disable-with="Sending…">Send</.btn>
        </div>
      </form>
    </div>
    """
  end

  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :active, :boolean, required: true

  defp stream_pill(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="toggle_stream"
      phx-value-stream={@name}
      class={[
        "px-2 py-0.5 rounded font-mono",
        if(@active,
          do: "bg-zinc-200 text-zinc-900 border border-zinc-300",
          else: "bg-zinc-100 text-zinc-400 border border-zinc-200 line-through"
        )
      ]}
    >
      {@label}
    </button>
    """
  end

  attr :event, :map, required: true

  defp event_line(%{event: %{kind: "stage"}} = assigns) do
    ~H"""
    <div class="text-amber-300">▸ stage: {@event.stage} · {@event.state} {@event.data}</div>
    """
  end

  defp event_line(%{event: %{kind: "output", stream: "stderr"}} = assigns) do
    ~H"""
    <div class="text-rose-300 whitespace-pre-wrap">{summarize(@event.data)}</div>
    """
  end

  defp event_line(assigns) do
    ~H"""
    <div class="text-zinc-200 whitespace-pre-wrap">{summarize(@event.data)}</div>
    """
  end

  # Claude stream-json is one JSON object per line. Pull out the human-relevant
  # bits (text content from assistant messages, tool_use commands, results)
  # so the timeline isn't a wall of JSON. Falls back to raw if we can't parse.
  defp summarize(data) when is_binary(data) do
    data
    |> String.split("\n", trim: true)
    |> Enum.map_join("\n", &summarize_line/1)
  end

  defp summarize(_), do: ""

  defp summarize_line(line) do
    case Jason.decode(line) do
      {:ok, %{"type" => "assistant", "message" => %{"content" => content}}} ->
        content
        |> Enum.map_join("", fn
          %{"type" => "text", "text" => t} ->
            t

          %{"type" => "thinking", "thinking" => t} ->
            "\n[thinking] " <> t

          %{"type" => "tool_use", "name" => name, "input" => input} ->
            "\n[#{name}] " <> Jason.encode!(input)

          _ ->
            ""
        end)

      {:ok, %{"type" => "user", "message" => %{"content" => content}}} ->
        content
        |> Enum.map_join("\n", fn
          %{"tool_use_id" => _, "content" => c} when is_binary(c) -> "→ " <> c
          _ -> ""
        end)

      {:ok, %{"type" => "result", "result" => r}} when is_binary(r) ->
        "✓ " <> r

      {:ok, %{"type" => "system", "subtype" => "init", "model" => model}} ->
        "[init: #{model}]"

      _ ->
        line
    end
  end
end
