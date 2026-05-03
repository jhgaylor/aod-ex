defmodule AgentOnDemandWeb.VaultControllerTest do
  use AgentOnDemandWeb.ConnCase, async: false

  describe "GET /api/vaults" do
    test "lists vaults", %{conn: conn} do
      vault = insert_vault(%{"name" => "list-test"})

      assert %{"data" => list} =
               conn |> authed() |> get(~p"/api/vaults") |> json_response(200)

      assert Enum.any?(list, &(&1["id"] == vault.id))
    end
  end

  describe "POST /api/vaults" do
    test "creates a vault", %{conn: conn} do
      payload = %{
        "name" => "ctrl-test-#{System.unique_integer([:positive])}",
        "description" => "x"
      }

      assert %{"data" => v} =
               conn |> authed() |> post_json(~p"/api/vaults", payload) |> json_response(201)

      assert v["name"] == payload["name"]
      assert v["description"] == "x"
    end

    test "422 on missing name", %{conn: conn} do
      response =
        conn
        |> authed()
        |> post_json(~p"/api/vaults", %{"description" => ""})
        |> json_response(422)

      assert response["errors"]
    end
  end

  describe "PUT + DELETE /api/vaults/:id" do
    test "updates", %{conn: conn} do
      vault = insert_vault(%{"name" => "to-update-#{System.unique_integer([:positive])}"})

      assert %{"data" => updated} =
               conn
               |> authed()
               |> put_json(~p"/api/vaults/#{vault.id}", %{"description" => "fresh"})
               |> json_response(200)

      assert updated["description"] == "fresh"
    end

    test "deletes", %{conn: conn} do
      vault = insert_vault()
      conn |> authed() |> delete(~p"/api/vaults/#{vault.id}") |> response(204)
    end
  end

  describe "vault secrets" do
    test "create + list + delete cycle", %{conn: conn} do
      vault = insert_vault()

      # create
      assert %{"data" => secret} =
               conn
               |> authed()
               |> post_json(~p"/api/vaults/#{vault.id}/secrets", %{
                 "key" => "GITHUB_TOKEN",
                 "value" => "ghp_xyz"
               })
               |> json_response(201)

      assert secret["key"] == "GITHUB_TOKEN"
      refute Map.has_key?(secret, "value")

      # list — never exposes value
      assert %{"data" => [listed]} =
               conn
               |> authed()
               |> get(~p"/api/vaults/#{vault.id}/secrets")
               |> json_response(200)

      assert listed["key"] == "GITHUB_TOKEN"
      refute Map.has_key?(listed, "value")

      # delete by key
      conn
      |> authed()
      |> delete(~p"/api/vaults/#{vault.id}/secrets/GITHUB_TOKEN")
      |> response(204)

      assert %{"data" => []} =
               conn
               |> authed()
               |> get(~p"/api/vaults/#{vault.id}/secrets")
               |> json_response(200)
    end

    test "404 on unknown vault", %{conn: conn} do
      conn
      |> authed()
      |> get(~p"/api/vaults/#{Ecto.UUID.generate()}/secrets")
      |> response(404)
    end
  end
end
