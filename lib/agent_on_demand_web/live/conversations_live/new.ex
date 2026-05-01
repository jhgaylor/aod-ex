defmodule AgentOnDemandWeb.ConversationsLive.New do
  use AgentOnDemandWeb, :live_view

  alias AgentOnDemand.{Agents, Conversations}

  @impl true
  def mount(_params, _session, socket) do
    agents = Agents.list_agents()

    {:ok,
     socket
     |> assign(:page_title, "New conversation")
     |> assign(:agents, agents)
     |> assign(:form, %{"agent_id" => first_agent_id(agents), "prompt" => ""})}
  end

  @impl true
  def handle_event("validate", %{"conv" => params}, socket) do
    {:noreply, assign(socket, :form, params)}
  end

  def handle_event("submit", %{"conv" => params}, socket) do
    case Conversations.start_conversation(params) do
      {:ok, conv} ->
        {:noreply,
         socket
         |> put_flash(:info, "Conversation started")
         |> push_navigate(to: ~p"/conversations/#{conv.id}")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Agent not found")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed: #{inspect(reason)}")}
    end
  end

  defp first_agent_id([]), do: nil
  defp first_agent_id([a | _]), do: a.id

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-2xl space-y-6">
      <h1 class="text-2xl font-semibold">New conversation</h1>

      <div :if={@agents == []} class="rounded border border-dashed border-zinc-300 p-8 text-center text-zinc-500 space-y-2">
        <div>No agents defined yet.</div>
        <.link navigate={~p"/agents/new"} class="text-zinc-900 underline">Create one</.link>
      </div>

      <form :if={@agents != []} phx-change="validate" phx-submit="submit" class="space-y-4 bg-white rounded shadow p-6 border border-zinc-200">
        <div class="space-y-1">
          <label class="block text-sm font-medium text-zinc-700">Agent</label>
          <select name="conv[agent_id]" class="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm">
            <option :for={a <- @agents} value={a.id} selected={@form["agent_id"] == a.id}>
              {a.name} ({a.runtime} · {a.model})
            </option>
          </select>
        </div>
        <.input id="prompt" name="conv[prompt]" type="textarea" label="First prompt"
          value={@form["prompt"]} rows="6" placeholder="What should the agent do?" autofocus required/>
        <div class="flex gap-2">
          <.btn type="submit" phx-disable-with="Starting…">Start</.btn>
          <.link navigate={~p"/"}><.btn_secondary>Cancel</.btn_secondary></.link>
        </div>
      </form>
    </div>
    """
  end
end
