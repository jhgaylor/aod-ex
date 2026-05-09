defmodule AgentOnDemandWeb.AdminController do
  @moduledoc false

  use AgentOnDemandWeb, :controller

  alias AgentOnDemand.Upgrader

  def upgrade(conn, _params) do
    case Upgrader.perform() do
      :ok ->
        spawn(fn -> Process.sleep(500); :init.stop(0) end)
        json(conn, %{status: "restarting"})

      {:error, :no_update} ->
        conn
        |> put_status(:conflict)
        |> json(%{error: "no update available"})

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: inspect(reason)})
    end
  end
end
