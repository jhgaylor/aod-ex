defmodule AgentOnDemandWeb.ConversationControllerTest do
  use AgentOnDemandWeb.ConnCase, async: true

  @create_params %{"prompt" => "hello", "runtime" => "claude"}

  describe "POST /api/conversations — source inference" do
    test "sets source to api when header is absent", %{conn: conn} do
      conn = post(conn, ~p"/api/conversations", @create_params)
      assert %{"source" => "api", "parent_conversation_id" => nil} = json_response(conn, 201)["data"]
    end

    test "sets source to api when header is empty string", %{conn: conn} do
      conn =
        conn
        |> put_req_header("x-aod-parent-conversation-id", "")
        |> post(~p"/api/conversations", @create_params)

      assert %{"source" => "api", "parent_conversation_id" => nil} = json_response(conn, 201)["data"]
    end

    test "sets source to agent and records parent_conversation_id when header is present", %{conn: conn} do
      parent_id = Ecto.UUID.generate()

      conn =
        conn
        |> put_req_header("x-aod-parent-conversation-id", parent_id)
        |> post(~p"/api/conversations", @create_params)

      assert %{"source" => "agent", "parent_conversation_id" => ^parent_id} =
               json_response(conn, 201)["data"]
    end
  end
end
