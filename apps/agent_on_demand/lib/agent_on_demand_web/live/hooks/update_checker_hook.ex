defmodule AgentOnDemandWeb.Hooks.UpdateCheckerHook do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView
  alias AgentOnDemand.{UpdateChecker, Upgrader}

  def on_mount(:default, _params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(AgentOnDemand.PubSub, "update_checker")
    end

    socket =
      socket
      |> assign(:update_status, fetch_status())
      |> attach_hook(:update_checker_info, :handle_info, &handle_info/2)
      |> attach_hook(:update_checker_event, :handle_event, &handle_event/3)

    {:cont, socket}
  end

  defp handle_info({:update_status, status}, socket) do
    {:halt, assign(socket, :update_status, status)}
  end

  defp handle_info(_msg, socket), do: {:cont, socket}

  defp handle_event("check_for_updates", _params, socket) do
    UpdateChecker.check_now()
    {:halt, socket}
  end

  defp handle_event("upgrade", _params, socket) do
    case Upgrader.perform() do
      :ok ->
        spawn(fn -> Process.sleep(500); :init.stop(0) end)
        {:halt, put_flash(socket, :info, "Upgrading… server will restart shortly.")}

      {:error, :no_update} ->
        {:halt, put_flash(socket, :error, "No update available.")}

      {:error, _reason} ->
        {:halt, put_flash(socket, :error, "Upgrade failed. Check server logs.")}
    end
  end

  defp handle_event(_event, _params, socket), do: {:cont, socket}

  defp fetch_status do
    UpdateChecker.get_status()
  rescue
    _ -> nil
  end
end
