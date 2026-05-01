defmodule AgentOnDemandWeb.EnvironmentControllerTest do
  use AgentOnDemandWeb.ConnCase, async: false

  describe "GET /api/environments" do
    test "lists envs", %{conn: conn} do
      env = insert_env(%{"name" => "list-test"})

      assert %{"data" => list} =
               conn |> authed() |> get(~p"/api/environments") |> json_response(200)

      assert Enum.any?(list, &(&1["id"] == env.id))
    end
  end

  describe "POST /api/environments" do
    test "creates an environment with all the new fields", %{conn: conn} do
      payload = %{
        "name" => "ctrl-test-#{System.unique_integer([:positive])}",
        "packages" => %{"apt" => ["jq"]},
        "env_vars" => %{"FOO" => "bar"},
        "setup_script" => "echo hi",
        "networking_type" => "limited",
        "networking_config" => %{"allowed_hosts" => ["github.com"]},
        "repositories" => [
          %{
            "url" => "https://github.com/foo/bar",
            "mount_path" => "/workspace/bar"
          }
        ]
      }

      assert %{"data" => env} =
               conn
               |> authed()
               |> post_json(~p"/api/environments", payload)
               |> json_response(201)

      assert env["name"] == payload["name"]
      assert env["packages"] == %{"apt" => ["jq"]}
      assert env["repositories"] == [
               %{"url" => "https://github.com/foo/bar", "mount_path" => "/workspace/bar"}
             ]
    end

    test "422 on invalid name", %{conn: conn} do
      response =
        conn |> authed() |> post_json(~p"/api/environments", %{"name" => ""}) |> json_response(422)

      assert response["errors"]
    end

    test "422 on invalid repository spec", %{conn: conn} do
      payload = %{
        "name" => "bad-repos-#{System.unique_integer([:positive])}",
        "repositories" => [%{"url" => "git://github.com/foo/bar", "mount_path" => "rel"}]
      }

      response =
        conn |> authed() |> post_json(~p"/api/environments", payload) |> json_response(422)

      assert response["errors"]
    end
  end

  describe "PUT + DELETE /api/environments/:id" do
    test "updates", %{conn: conn} do
      env = insert_env(%{"name" => "to-update-#{System.unique_integer([:positive])}"})

      assert %{"data" => updated} =
               conn
               |> authed()
               |> put_json(~p"/api/environments/#{env.id}", %{"setup_script" => "echo updated"})
               |> json_response(200)

      assert updated["setup_script"] == "echo updated"
    end

    test "204 on delete; subsequent GET 404", %{conn: conn} do
      env = insert_env()

      assert conn |> authed() |> delete(~p"/api/environments/#{env.id}") |> response(204)
      assert conn |> authed() |> get(~p"/api/environments/#{env.id}") |> json_response(404)
    end
  end

  describe "secrets nested under env" do
    setup %{conn: conn} do
      {:ok, conn: authed(conn), env: insert_env()}
    end

    test "create secret returns 201 without value", %{conn: conn, env: env} do
      assert %{"data" => secret} =
               post_json(conn, ~p"/api/environments/#{env.id}/secrets", %{
                 "key" => "GITHUB_TOKEN",
                 "value" => "ghp_secret"
               })
               |> json_response(201)

      assert secret["key"] == "GITHUB_TOKEN"
      refute secret["value"]
      refute secret["value_ciphertext"]
    end

    test "list secrets never includes values", %{conn: conn, env: env} do
      insert_secret(env, %{"key" => "API_KEY", "value" => "should-not-leak"})

      assert %{"data" => list} =
               get(conn, ~p"/api/environments/#{env.id}/secrets") |> json_response(200)

      refute Enum.any?(list, fn s -> Map.has_key?(s, "value") end)
      refute :erlang.term_to_binary(list) |> :binary.match("should-not-leak") != :nomatch
    end
  end
end
