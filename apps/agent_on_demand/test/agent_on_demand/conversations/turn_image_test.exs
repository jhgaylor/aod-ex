defmodule AgentOnDemand.Conversations.TurnImageTest do
  use AgentOnDemand.DataCase, async: true

  alias AgentOnDemand.Conversations.TurnImage

  describe "changeset/2" do
    test "valid attrs produce valid changeset" do
      attrs = %{
        position: 0,
        media_type: "image/png",
        data: <<1, 2, 3>>,
        turn_id: Ecto.UUID.generate()
      }
      cs = TurnImage.changeset(%TurnImage{}, attrs)
      assert cs.valid?
    end

    test "invalid media_type is rejected" do
      attrs = %{
        position: 0,
        media_type: "image/bmp",
        data: <<1, 2, 3>>,
        turn_id: Ecto.UUID.generate()
      }
      cs = TurnImage.changeset(%TurnImage{}, attrs)
      refute cs.valid?
      assert %{media_type: ["is invalid"]} = errors_on(cs)
    end

    test "missing required fields are rejected" do
      cs = TurnImage.changeset(%TurnImage{}, %{})
      refute cs.valid?
      assert %{position: _, media_type: _, data: _, turn_id: _} = errors_on(cs)
    end

    test "all valid media types are accepted" do
      for mt <- ~w(image/png image/jpeg image/gif image/webp) do
        attrs = %{
          position: 0,
          media_type: mt,
          data: <<1, 2, 3>>,
          turn_id: Ecto.UUID.generate()
        }
        cs = TurnImage.changeset(%TurnImage{}, attrs)
        assert cs.valid?, "expected #{mt} to be valid"
      end
    end
  end
end
