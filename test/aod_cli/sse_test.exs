defmodule AodCli.SseTest do
  use ExUnit.Case, async: true

  alias AodCli.Sse

  describe "feed/1" do
    test "returns {[], buffer} when no complete event" do
      assert {[], "id: 1\nevent: foo"} = Sse.feed("id: 1\nevent: foo")
    end

    test "parses a single complete event" do
      input = "id: 1\nevent: stage\ndata: {}\n\n"
      assert {[event], ""} = Sse.feed(input)
      assert event.id == 1
      assert event.event == "stage"
      assert event.data == %{}
    end

    test "parses multiple events in one chunk" do
      input = "id: 1\nevent: a\ndata: {}\n\nid: 2\nevent: b\ndata: {}\n\n"
      assert {[a, b], ""} = Sse.feed(input)
      assert a.id == 1
      assert b.id == 2
    end

    test "leaves incomplete trailing event in buffer" do
      input = "id: 1\nevent: a\ndata: {}\n\nid: 2\nevent: b"
      assert {[a], "id: 2\nevent: b"} = Sse.feed(input)
      assert a.id == 1
    end

    test "ignores heartbeat (comment) lines" do
      input = ": heartbeat\n\nid: 1\ndata: {}\n\n"
      assert {[event], ""} = Sse.feed(input)
      assert event.id == 1
    end

    test "decodes data as JSON when valid" do
      input = ~s|id: 1\nevent: x\ndata: {"foo":"bar"}\n\n|
      assert {[event], ""} = Sse.feed(input)
      assert event.data == %{"foo" => "bar"}
    end

    test "passes data through as binary when not JSON" do
      input = "id: 1\nevent: x\ndata: not-json\n\n"
      assert {[event], ""} = Sse.feed(input)
      assert event.data == "not-json"
    end

    test "handles missing optional fields" do
      input = "data: {}\n\n"
      assert {[event], ""} = Sse.feed(input)
      assert event.data == %{}
      refute Map.has_key?(event, :id)
      refute Map.has_key?(event, :event)
    end

    test "id parses as integer (defaults 0 on garbage)" do
      input = "id: abc\ndata: {}\n\n"
      assert {[event], ""} = Sse.feed(input)
      assert event.id == 0
    end
  end
end
