defmodule AgentOnDemandWeb.AuthTest do
  use AgentOnDemandWeb.ConnCase, async: false

  describe "/health is unauthenticated" do
    test "GET /health returns 200 without auth", %{conn: conn} do
      assert conn |> get(~p"/health") |> json_response(200) == %{"status" => "ok"}
    end
  end

  describe "/api/* requires bearer auth" do
    test "GET /api/agents 401 without auth", %{conn: conn} do
      assert conn |> get(~p"/api/agents") |> response(401)
    end

    test "GET /api/agents 200 with valid bearer", %{conn: conn} do
      assert %{"data" => _} =
               conn
               |> authed()
               |> get(~p"/api/agents")
               |> json_response(200)
    end

    test "wrong bearer is rejected", %{conn: conn} do
      conn = put_req_header(conn, "authorization", "Bearer not-the-token")
      assert get(conn, ~p"/api/agents") |> response(401)
    end

    test "no auth on /api/environments returns 401", %{conn: conn} do
      assert get(conn, ~p"/api/environments") |> response(401)
    end
  end

  describe "browser routes redirect to /login when unauthed" do
    test "GET / unauthed redirects", %{conn: conn} do
      assert conn |> get(~p"/") |> response(302)
    end

    test "GET /agents unauthed redirects", %{conn: conn} do
      assert conn |> get(~p"/agents") |> response(302)
    end
  end
end
