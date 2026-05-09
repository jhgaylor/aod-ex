defmodule AgentOnDemandWeb.AdminControllerTest do
  use AgentOnDemandWeb.ConnCase
  use Mimic

  alias AgentOnDemand.Upgrader

  setup do
    stub(Upgrader, :perform, fn -> :ok end)
    stub(Upgrader, :schedule_restart, fn -> :ok end)
    :ok
  end

  describe "POST /admin/upgrade" do
    test "returns 200 with status restarting on success", %{conn: conn} do
      conn = conn |> login() |> post(~p"/admin/upgrade")
      assert json_response(conn, 200) == %{"status" => "restarting"}
    end

    test "returns 409 when no update available", %{conn: conn} do
      stub(Upgrader, :perform, fn -> {:error, :no_update} end)

      conn = conn |> login() |> post(~p"/admin/upgrade")
      assert json_response(conn, 409) == %{"error" => "no update available"}
    end

    test "returns 500 on upgrade failure", %{conn: conn} do
      stub(Upgrader, :perform, fn -> {:error, :download_failed} end)

      conn = conn |> login() |> post(~p"/admin/upgrade")
      assert %{"error" => _} = json_response(conn, 500)
    end

    test "redirects to login when not authenticated", %{conn: conn} do
      conn = post(conn, ~p"/admin/upgrade")
      assert redirected_to(conn) =~ "/login"
    end
  end
end
