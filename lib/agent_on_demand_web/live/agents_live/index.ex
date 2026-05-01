defmodule AgentOnDemandWeb.AgentsLive.Index do
  use AgentOnDemandWeb, :live_view

  alias AgentOnDemand.Agents

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Agents")
     |> assign(:agents, Agents.list_agents())}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    agent = Agents.get_agent!(id)
    {:ok, _} = Agents.delete_agent(agent)

    {:noreply,
     socket
     |> assign(:agents, Agents.list_agents())
     |> put_flash(:info, "Deleted #{agent.name}")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-4">
      <div class="flex items-center justify-between">
        <h1 class="text-2xl font-semibold">Agents</h1>
        <.link navigate={~p"/agents/new"}><.btn>+ New agent</.btn></.link>
      </div>

      <div :if={@agents == []} class="rounded border border-dashed border-zinc-300 p-8 text-center text-zinc-500">
        No agents yet.
      </div>

      <table :if={@agents != []} class="w-full text-sm bg-white rounded shadow border border-zinc-200">
        <thead class="text-left text-zinc-500 border-b border-zinc-200">
          <tr>
            <th class="px-4 py-2">Name</th>
            <th class="px-4 py-2">Runtime</th>
            <th class="px-4 py-2">Model</th>
            <th class="px-4 py-2">Env</th>
            <th class="px-4 py-2"></th>
          </tr>
        </thead>
        <tbody>
          <tr :for={a <- @agents} class="border-b border-zinc-100 last:border-0 hover:bg-zinc-50">
            <td class="px-4 py-2 font-medium">{a.name}</td>
            <td class="px-4 py-2 text-zinc-600">{a.runtime}</td>
            <td class="px-4 py-2 text-zinc-600 font-mono text-xs">{a.model}</td>
            <td class="px-4 py-2 text-zinc-600">{env_name(a.environment)}</td>
            <td class="px-4 py-2 text-right space-x-2">
              <.link navigate={~p"/agents/#{a.id}/edit"}><.btn_secondary>Edit</.btn_secondary></.link>
              <.btn_danger phx-click="delete" phx-value-id={a.id} data-confirm="Delete agent?">Delete</.btn_danger>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  defp env_name(nil), do: "—"
  defp env_name(env), do: env.name
end
