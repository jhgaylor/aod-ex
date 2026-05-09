defmodule AgentOnDemandWeb.TurnImageControllerTest do
  use AgentOnDemandWeb.ConnCase, async: true

  alias AgentOnDemand.Conversations

  setup %{conn: conn} do
    {:ok, conn: authed(conn)}
  end

  describe "GET /api/conversations/:conversation_id/turns/:turn_id/images/:position" do
    test "returns 404 for non-existent turn", %{conn: conn} do
      conv = insert_conversation()
      fake_turn_id = Ecto.UUID.generate()

      conn = get(conn, ~p"/api/conversations/#{conv.id}/turns/#{fake_turn_id}/images/0")
      assert response(conn, 404)
    end

    test "returns 404 for turn from different conversation", %{conn: conn} do
      conv1 = insert_conversation()
      conv2 = insert_conversation()
      turn = insert_turn(conv1)

      conn = get(conn, ~p"/api/conversations/#{conv2.id}/turns/#{turn.id}/images/0")
      assert response(conn, 404)
    end

    test "returns 404 when position does not exist", %{conn: conn} do
      conv = insert_conversation()
      turn = insert_turn(conv)

      conn = get(conn, ~p"/api/conversations/#{conv.id}/turns/#{turn.id}/images/0")
      assert response(conn, 404)
    end

    test "returns image bytes with correct content type", %{conn: conn} do
      conv = insert_conversation()
      turn = insert_turn(conv)
      png_data = <<137, 80, 78, 71>>

      {:ok, _} = Conversations.insert_turn_images(turn.id, [
        %{media_type: "image/png", data: png_data}
      ])

      conn = get(conn, ~p"/api/conversations/#{conv.id}/turns/#{turn.id}/images/0")
      assert response(conn, 200) == png_data
      assert response_content_type(conn, :png) =~ "image/png"
    end
  end
end
