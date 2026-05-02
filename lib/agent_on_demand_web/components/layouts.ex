defmodule AgentOnDemandWeb.Layouts do
  use AgentOnDemandWeb, :html

  embed_templates "layouts/*"

  alias AgentOnDemand.Conversations

  def app(assigns) do
    convs = Conversations.list_active_conversations()
    assigns = assign(assigns, :nav_conversations, convs)

    ~H"""
    <main class="min-h-screen bg-zinc-50 text-zinc-900">
      <.flash_group flash={@flash} />
      <div class="flex">
        <aside class="hidden md:flex flex-col w-56 h-screen sticky top-0 border-r border-zinc-200 bg-white">
          <div class="p-4 border-b border-zinc-200 shrink-0">
            <a href={~p"/"} class="text-lg font-semibold tracking-tight">AoD</a>
            <div class="text-xs text-zinc-500">agent on demand</div>
          </div>

          <div class="px-2 pt-2 shrink-0">
            <.nav_link href={~p"/"} label="Conversations" current={@current_path}/>
          </div>

          <nav class="px-2 py-1 text-sm flex-1 min-h-0 overflow-y-auto">
            <div :if={@nav_conversations == []} class="px-3 py-2 text-xs text-zinc-400 italic">
              no active conversations
            </div>
            <%= for conv <- @nav_conversations do %>
              <.conv_nav_link conv={conv} current={@current_path}/>
            <% end %>
          </nav>

          <div class="border-t border-zinc-200 px-2 py-2 shrink-0">
            <.nav_link href={~p"/help"} label="Help" current={@current_path}/>
          </div>

          <div class="border-t border-zinc-200 px-2 py-2 shrink-0">
            <div class="px-3 pt-1 pb-1 text-[10px] uppercase tracking-wider text-zinc-400 font-medium">
              Configure
            </div>
            <.nav_link href={~p"/agents"} label="Agents" current={@current_path}/>
            <.nav_link href={~p"/environments"} label="Environments" current={@current_path}/>
            <.nav_link href={~p"/audit"} label="Audit log" current={@current_path}/>
          </div>

          <div class="border-t border-zinc-200 px-2 py-3 text-xs text-zinc-500 shrink-0">
            <a href={~p"/logout"} data-method="post" class="block px-3 py-1 hover:text-zinc-800">Sign out</a>
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
      "block rounded px-3 py-1.5 text-sm hover:bg-zinc-100",
      @active && "bg-zinc-100 font-medium",
      not @active && "text-zinc-600"
    ]}>{@label}</a>
    """
  end

  attr :conv, :map, required: true
  attr :current, :string, default: ""

  defp conv_nav_link(assigns) do
    href = "/conversations/#{assigns.conv.id}"
    active = assigns.current == href

    label =
      cond do
        assigns.conv.agent && assigns.conv.agent.name -> assigns.conv.agent.name
        true -> binary_part(assigns.conv.id, 0, 8)
      end

    {dot_class, status_label} =
      case assigns.conv.status do
        "running" -> {"bg-emerald-500 animate-pulse", "running"}
        "idle" -> {"bg-zinc-400", "idle"}
        "pending" -> {"bg-amber-400", "pending"}
        other -> {"bg-zinc-300", other}
      end

    assigns =
      assign(assigns,
        href: href,
        active: active,
        label: label,
        dot_class: dot_class,
        status_label: status_label
      )

    ~H"""
    <a href={@href} class={[
      "flex items-center gap-2 rounded px-3 py-1.5 text-sm hover:bg-zinc-100 group",
      @active && "bg-zinc-100 font-medium",
      not @active && "text-zinc-600"
    ]}>
      <span class={["size-2 rounded-full shrink-0", @dot_class]} title={@status_label}/>
      <span class="truncate flex-1">{@label}</span>
      <span class="text-[10px] text-zinc-400 font-mono shrink-0 group-hover:text-zinc-500">
        {String.slice(@conv.id, 0, 4)}
      </span>
    </a>
    """
  end
end
