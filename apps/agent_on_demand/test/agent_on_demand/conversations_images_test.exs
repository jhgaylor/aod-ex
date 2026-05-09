defmodule AgentOnDemand.ConversationsImagesTest do
  use AgentOnDemand.DataCase, async: true

  import AgentOnDemand.Factory

  alias AgentOnDemand.Conversations

  describe "insert_turn_images/2" do
    test "inserts multiple images for a turn" do
      conv = insert_conversation()
      turn = insert_turn(conv)

      images = [
        %{media_type: "image/png", data: <<1, 2, 3>>},
        %{media_type: "image/jpeg", data: <<4, 5, 6>>}
      ]

      assert {:ok, 2} = Conversations.insert_turn_images(turn.id, images)
    end

    test "returns {:ok, []} for empty images list" do
      assert {:ok, []} = Conversations.insert_turn_images(Ecto.UUID.generate(), [])
    end

    test "assigns correct positions (0-indexed)" do
      conv = insert_conversation()
      turn = insert_turn(conv)

      images = [
        %{media_type: "image/png", data: <<1>>},
        %{media_type: "image/gif", data: <<2>>},
        %{media_type: "image/webp", data: <<3>>}
      ]

      {:ok, 3} = Conversations.insert_turn_images(turn.id, images)

      img0 = Conversations.get_turn_image(turn.id, 0)
      img1 = Conversations.get_turn_image(turn.id, 1)
      img2 = Conversations.get_turn_image(turn.id, 2)

      assert img0.media_type == "image/png"
      assert img0.data == <<1>>
      assert img1.media_type == "image/gif"
      assert img2.media_type == "image/webp"
    end
  end

  describe "get_turn_image/2" do
    test "returns nil for non-existent position" do
      conv = insert_conversation()
      turn = insert_turn(conv)
      assert nil == Conversations.get_turn_image(turn.id, 99)
    end

    test "returns the correct image by turn_id and position" do
      conv = insert_conversation()
      turn = insert_turn(conv)
      images = [%{media_type: "image/png", data: <<0xFF, 0xFE>>}]
      {:ok, 1} = Conversations.insert_turn_images(turn.id, images)

      img = Conversations.get_turn_image(turn.id, 0)
      assert img.media_type == "image/png"
      assert img.data == <<0xFF, 0xFE>>
    end
  end

  describe "get_turn_by_conversation/2" do
    test "returns nil when turn belongs to different conversation" do
      conv1 = insert_conversation()
      conv2 = insert_conversation()
      turn = insert_turn(conv1)

      assert nil == Conversations.get_turn_by_conversation(turn.id, conv2.id)
    end

    test "returns turn when ids match" do
      conv = insert_conversation()
      turn = insert_turn(conv)

      found = Conversations.get_turn_by_conversation(turn.id, conv.id)
      assert found.id == turn.id
    end
  end
end
