defmodule AgentOnDemandWeb.ConversationsLive.Index do
  use AgentOnDemandWeb, :live_view

  alias AgentOnDemand.{Agents, Conversations}

  @poll_interval 2_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :tick, @poll_interval)

    {:ok,
     socket
     |> assign(:page_title, "Conversations")
     |> assign(:sort_by, :inserted_at)
     |> assign(:sort_dir, :desc)
     |> load_data()}
  end

  @impl true
  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, @poll_interval)
    {:noreply, load_data(socket)}
  end

  @impl true
  def handle_event("terminate", %{"id" => id}, socket) do
    case AgentOnDemand.Conversations.ConversationServer.terminate(id) do
      :ok -> {:noreply, socket |> put_flash(:info, "Terminated") |> load_data()}
      _ -> {:noreply, put_flash(socket, :error, "Not running")}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case Conversations.get_conversation(id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Not found")}

      conv ->
        {:ok, _} = Conversations.delete_conversation(conv)
        {:noreply, socket |> put_flash(:info, "Deleted") |> load_data()}
    end
  end

  def handle_event("sort", %{"by" => field_str}, socket) do
    field = parse_sort_field(field_str)

    {sort_by, sort_dir} =
      if socket.assigns.sort_by == field do
        {field, toggle_dir(socket.assigns.sort_dir)}
      else
        {field, :desc}
      end

    {:noreply,
     socket
     |> assign(sort_by: sort_by, sort_dir: sort_dir)
     |> load_data()}
  end

  defp load_data(socket) do
    convs = Conversations.list_conversations()
    agents = Agents.list_agents()

    sorted = sort_conversations(convs, socket.assigns.sort_by, socket.assigns.sort_dir)

    assign(socket,
      conversations: sorted,
      agents_by_id: Map.new(agents, &{&1.id, &1})
    )
  end

  defp sort_conversations(convs, field, :asc) do
    Enum.sort_by(convs, &Map.get(&1, field), DateTime)
  end

  defp sort_conversations(convs, field, :desc) do
    Enum.sort_by(convs, &Map.get(&1, field), {:desc, DateTime})
  end

  defp toggle_dir(:asc), do: :desc
  defp toggle_dir(:desc), do: :asc

  defp parse_sort_field("inserted_at"), do: :inserted_at
  defp parse_sort_field("updated_at"), do: :updated_at
  defp parse_sort_field(_), do: :inserted_at

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-4">
      <div class="flex items-center justify-between">
        <h1 class="text-2xl font-semibold">Conversations</h1>
        <.link navigate={~p"/conversations/new"}>
          <.btn>+ New conversation</.btn>
        </.link>
      </div>

      <div :if={@conversations == []} class="rounded border border-dashed border-zinc-300 p-8 text-center text-zinc-500">
        No conversations yet. Start one to see it here.
      </div>

      <table :if={@conversations != []} class="w-full text-sm bg-white rounded shadow border border-zinc-200 table-fixed">
        <thead class="text-left text-zinc-500 border-b border-zinc-200">
          <tr>
            <th class="px-4 py-2">Status</th>
            <th class="px-4 py-2">Task</th>
            <th class="px-4 py-2">Agent</th>
            <th class="px-4 py-2">Runtime</th>
            <th
              class={["px-4 py-2 cursor-pointer select-none whitespace-nowrap", @sort_by == :inserted_at && "text-zinc-900 font-medium"]}
              phx-click="sort"
              phx-value-by="inserted_at"
            >Started {sort_arrow(@sort_by, @sort_dir, :inserted_at)}</th>
            <th
              class={["px-4 py-2 cursor-pointer select-none whitespace-nowrap", @sort_by == :updated_at && "text-zinc-900 font-medium"]}
              phx-click="sort"
              phx-value-by="updated_at"
            >Last active {sort_arrow(@sort_by, @sort_dir, :updated_at)}</th>
            <th class="px-4 py-2"></th>
          </tr>
        </thead>
        <tbody>
          <tr :for={c <- @conversations} class="border-b border-zinc-100 last:border-0 hover:bg-zinc-50">
            <td class="px-4 py-2"><.status_badge status={c.status} /></td>
            <td class="px-4 py-2 text-zinc-700">
              <%= case first_prompt(c) do %>
                <% nil -> %><span class="text-zinc-400">—</span>
                <% prompt -> %><span class="block line-clamp-2" title={prompt}>{prompt}</span>
              <% end %>
            </td>
            <td class="px-4 py-2">
              <.link navigate={~p"/conversations/#{c.id}"} class="text-zinc-900 hover:underline font-medium">
                {agent_name(@agents_by_id, c.agent_id)}
              </.link>
              <div class="text-xs text-zinc-400 font-mono">{short(c.id)}</div>
            </td>
            <td class="px-4 py-2 text-zinc-600">{c.runtime}</td>
            <td class="px-4 py-2 text-zinc-500">{relative_time(c.inserted_at)}</td>
            <td class="px-4 py-2 text-zinc-500">{relative_time(c.updated_at)}</td>
            <td class="px-4 py-2 text-right space-x-2 whitespace-nowrap">
              <.btn_danger :if={c.status not in ["terminated", "completed", "failed"]}
                phx-click="terminate" phx-value-id={c.id}
                data-confirm="Terminate this conversation?">
                Terminate
              </.btn_danger>
              <.btn_secondary phx-click="delete" phx-value-id={c.id}
                data-confirm="Delete this conversation and all its turns? This cannot be undone.">
                Delete
              </.btn_secondary>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  defp agent_name(_agents_by_id, nil), do: "(no agent)"

  defp agent_name(agents_by_id, id) do
    case Map.get(agents_by_id, id) do
      nil -> "(deleted agent)"
      a -> a.name
    end
  end

  defp short(id), do: binary_part(id, 0, 8)

  defp relative_time(nil), do: ""

  defp relative_time(dt) do
    secs = DateTime.diff(DateTime.utc_now(), dt)

    cond do
      secs < 60 -> "#{secs}s ago"
      secs < 3600 -> "#{div(secs, 60)}m ago"
      secs < 86_400 -> "#{div(secs, 3600)}h ago"
      true -> "#{div(secs, 86_400)}d ago"
    end
  end

  defp first_prompt(conv) do
    case conv.turns do
      %Ecto.Association.NotLoaded{} -> nil
      [] -> nil
      [%{prompt: prompt} | _] ->
        prompt |> String.trim() |> String.replace(~r/\s+/, " ")
    end
  end

  defp sort_arrow(current, dir, field) when current == field do
    if dir == :asc, do: "↑", else: "↓"
  end

  defp sort_arrow(_current, _dir, _field), do: "↕"
end
