defmodule AgentOnDemand.UpgraderTest do
  use ExUnit.Case, async: true
  use Mimic

  alias AgentOnDemand.{GithubReleases, UpdateChecker, Upgrader}

  @asset %{
    "name" => "aod-server-linux-x86_64",
    "url" => "https://api.github.com/repos/jhgaylor/aod-ex/releases/assets/1"
  }

  @release %{"tag_name" => "v0.2.18", "assets" => [@asset]}

  setup do
    # Always point exe_path to a temp file so we don't mess with real binaries
    tmp = System.tmp_dir!() <> "/aod_test_#{System.unique_integer([:positive])}"
    File.write!(tmp, "old binary")
    System.put_env("AOD_BINARY_PATH", tmp)

    on_exit(fn ->
      System.delete_env("AOD_BINARY_PATH")
      File.rm(tmp)
    end)

    {:ok, tmp_path: tmp}
  end

  describe "perform/0" do
    test "returns {:error, :no_update} when no update available" do
      stub(UpdateChecker, :get_status, fn -> %{has_update: false} end)

      assert {:error, :no_update} = Upgrader.perform()
    end

    test "downloads binary, renames to exe_path, returns :ok", %{tmp_path: target} do
      stub(UpdateChecker, :get_status, fn -> %{has_update: true} end)
      stub(GithubReleases, :get_latest_release, fn -> {:ok, @release} end)
      stub(GithubReleases, :find_asset, fn _release, "aod-server-linux-x86_64" -> {:ok, @asset} end)

      stub(GithubReleases, :download_asset, fn _asset, dest ->
        File.write!(dest, "new binary")
        :ok
      end)

      assert :ok = Upgrader.perform()
      assert File.read!(target) == "new binary"
      refute File.exists?(target <> ".new")
    end

    test "returns error when download fails" do
      stub(UpdateChecker, :get_status, fn -> %{has_update: true} end)
      stub(GithubReleases, :get_latest_release, fn -> {:ok, @release} end)
      stub(GithubReleases, :find_asset, fn _release, _ -> {:ok, @asset} end)
      stub(GithubReleases, :download_asset, fn _asset, _dest -> {:error, :timeout} end)

      assert {:error, :timeout} = Upgrader.perform()
    end

    test "returns error when asset not found in release" do
      stub(UpdateChecker, :get_status, fn -> %{has_update: true} end)
      stub(GithubReleases, :get_latest_release, fn -> {:ok, %{"tag_name" => "v0.2.18", "assets" => []}} end)
      stub(GithubReleases, :find_asset, fn _release, _ -> {:error, :not_found} end)

      assert {:error, :not_found} = Upgrader.perform()
    end
  end

  describe "exe_path/0" do
    test "returns AOD_BINARY_PATH when set" do
      System.put_env("AOD_BINARY_PATH", "/opt/aod/aod_server")
      assert Upgrader.exe_path() == "/opt/aod/aod_server"
    end

    test "falls back to RELEASE_BIN when AOD_BINARY_PATH not set" do
      System.delete_env("AOD_BINARY_PATH")
      System.put_env("RELEASE_BIN", "/opt/aod/bin/aod_server")
      assert Upgrader.exe_path() == "/opt/aod/bin/aod_server"
      System.delete_env("RELEASE_BIN")
    end
  end
end
