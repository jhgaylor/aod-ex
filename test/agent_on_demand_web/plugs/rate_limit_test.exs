defmodule AgentOnDemandWeb.Plugs.RateLimitTest do
  use ExUnit.Case, async: false

  alias AgentOnDemandWeb.Plugs.RateLimit

  setup do
    RateLimit.ensure_table()
    # Each test gets its own bucket so they don't share counters
    bucket = "test-#{System.unique_integer([:positive])}"
    {:ok, opts: %{bucket: bucket, max: 3, window_ms: 60_000}}
  end

  describe "bump/2" do
    test "first 3 requests pass; 4th is limited", %{opts: opts} do
      key = {opts.bucket, "1.1.1.1"}
      assert :ok = RateLimit.bump(key, opts)
      assert :ok = RateLimit.bump(key, opts)
      assert :ok = RateLimit.bump(key, opts)
      assert {:limited, retry} = RateLimit.bump(key, opts)
      assert retry > 0
    end

    test "different keys have independent counters", %{opts: opts} do
      a = {opts.bucket, "1.1.1.1"}
      b = {opts.bucket, "2.2.2.2"}
      :ok = RateLimit.bump(a, opts)
      :ok = RateLimit.bump(a, opts)
      :ok = RateLimit.bump(a, opts)
      assert {:limited, _} = RateLimit.bump(a, opts)
      # b's counter is fresh
      assert :ok = RateLimit.bump(b, opts)
    end

    test "expired window resets the count", %{opts: opts} do
      key = {opts.bucket, "1.1.1.1"}
      # Expired window: started_at far in the past
      now = System.system_time(:millisecond)
      :ets.insert(RateLimit.table(), {key, now - 120_000, 999})
      assert :ok = RateLimit.bump(key, opts)
      assert :ok = RateLimit.bump(key, opts)
      # And we shouldn't be at the limit because the count reset
      assert :ok = RateLimit.bump(key, opts)
    end
  end

  describe "call/2 (Plug)" do
    import Plug.Test, only: [conn: 3]

    test "passes the conn through under limit" do
      opts = RateLimit.init(bucket: "plug-test-#{System.unique_integer([:positive])}", max: 1)

      passed =
        conn(:get, "/api/anything", "")
        |> Map.put(:remote_ip, {1, 2, 3, 4})
        |> RateLimit.call(opts)

      assert passed.halted == false
    end

    test "returns 429 with Retry-After header on overflow" do
      bucket = "plug-overflow-#{System.unique_integer([:positive])}"
      opts = RateLimit.init(bucket: bucket, max: 1)

      base = conn(:get, "/api/anything", "") |> Map.put(:remote_ip, {9, 9, 9, 9})

      first = RateLimit.call(base, opts)
      refute first.halted

      blocked = RateLimit.call(base, opts)
      assert blocked.halted
      assert blocked.status == 429
      assert {"retry-after", _} = List.keyfind(blocked.resp_headers, "retry-after", 0)
    end
  end
end
