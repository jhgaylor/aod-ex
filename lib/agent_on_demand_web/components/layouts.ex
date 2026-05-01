defmodule AgentOnDemandWeb.Layouts do
  use AgentOnDemandWeb, :html

  embed_templates "layouts/*"

  def app(assigns) do
    ~H"""
    <main class="min-h-screen bg-zinc-50 text-zinc-900">
      <.flash_group flash={@flash} />
      <div class="flex">
        <aside class="hidden md:block w-56 min-h-screen border-r border-zinc-200 bg-white">
          <div class="p-4 border-b border-zinc-200">
            <a href={~p"/"} class="text-lg font-semibold tracking-tight">AoD</a>
            <div class="text-xs text-zinc-500">agent on demand</div>
          </div>
          <nav class="p-2 space-y-1 text-sm">
            <.nav_link href={~p"/"} label="Conversations" current={@current_path}/>
            <.nav_link href={~p"/agents"} label="Agents" current={@current_path}/>
            <.nav_link href={~p"/environments"} label="Environments" current={@current_path}/>
          </nav>
          <div class="p-2 border-t border-zinc-200 mt-4 text-xs text-zinc-500">
            <a href={~p"/logout"} data-method="post" class="hover:text-zinc-800">Sign out</a>
          </div>
        </aside>
        <section class="flex-1 p-6">
          {@inner_content}
        </section>
      </div>
    </main>
    """
  end

  attr :href, :string, required: true
  attr :label, :string, required: true
  attr :current, :string, default: ""

  defp nav_link(assigns) do
    active = String.starts_with?(assigns.current || "", assigns.href) and assigns.href != "/"
    active = active or assigns.current == assigns.href

    assigns = assign(assigns, :active, active)

    ~H"""
    <a href={@href} class={[
      "block rounded px-3 py-2 hover:bg-zinc-100",
      @active && "bg-zinc-100 font-medium",
      not @active && "text-zinc-600"
    ]}>{@label}</a>
    """
  end
end
