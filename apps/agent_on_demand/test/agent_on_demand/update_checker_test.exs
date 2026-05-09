defmodule AgentOnDemand.UpdateCheckerTest do
  use ExUnit.Case, async: false
  use Mimic

  alias AgentOnDemand.{GithubReleases, UpdateChecker}

  describe "get_status/1" do
    test "returns initial state after first check completes" do
      stub(GithubReleases, :get_latest_release, fn ->
        {:ok, %{"tag_name" => "v0.2.17", "assets" => []}}
      end)

      checker = start_supervised!({UpdateChecker, name: nil})
      Process.sleep(50)
      status = GenServer.call(checker, :get_status)

      assert is_binary(status.current_version)
      assert status.has_update == false
      assert status.checking == false
    end
  end

  describe "check_now/1 and PubSub broadcasts" do
    test "broadcasts has_update: true when newer version found" do
      stub(GithubReleases, :get_latest_release, fn ->
        {:ok, %{"tag_name" => "v99.0.0", "assets" => []}}
      end)

      Phoenix.PubSub.subscribe(AgentOnDemand.PubSub, "update_checker")
      start_supervised!({UpdateChecker, name: nil})

      assert_receive {:update_status, %{has_update: true, latest_version: "99.0.0"}}, 2000
    end

    test "broadcasts has_update: false when same or older version" do
      stub(GithubReleases, :get_latest_release, fn ->
        {:ok, %{"tag_name" => "v0.0.1", "assets" => []}}
      end)

      Phoenix.PubSub.subscribe(AgentOnDemand.PubSub, "update_checker")
      start_supervised!({UpdateChecker, name: nil})

      assert_receive {:update_status, %{has_update: false}}, 2000
    end

    test "broadcasts checking: true before HTTP call, then false after" do
      stub(GithubReleases, :get_latest_release, fn ->
        {:ok, %{"tag_name" => "v0.2.17", "assets" => []}}
      end)

      Phoenix.PubSub.subscribe(AgentOnDemand.PubSub, "update_checker")
      start_supervised!({UpdateChecker, name: nil})

      assert_receive {:update_status, %{checking: true}}, 1000
      assert_receive {:update_status, %{checking: false}}, 1000
    end

    test "handles GitHub API error gracefully without crashing" do
      stub(GithubReleases, :get_latest_release, fn -> {:error, :timeout} end)

      Phoenix.PubSub.subscribe(AgentOnDemand.PubSub, "update_checker")
      checker = start_supervised!({UpdateChecker, name: nil})

      assert_receive {:update_status, %{checking: false}}, 1000
      assert Process.alive?(checker)
    end
  end
end
