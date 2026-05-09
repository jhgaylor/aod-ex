defmodule AgentOnDemand.GithubReleasesTest do
  use ExUnit.Case, async: true
  use Mimic

  alias AgentOnDemand.GithubReleases

  describe "get_latest_release/0" do
    test "returns release map on 200" do
      stub(Req, :get, fn _url, _opts ->
        {:ok, %Req.Response{status: 200, body: %{"tag_name" => "v0.2.18", "assets" => []}}}
      end)

      assert {:ok, %{"tag_name" => "v0.2.18"}} = GithubReleases.get_latest_release()
    end

    test "returns error on non-200" do
      stub(Req, :get, fn _url, _opts ->
        {:ok, %Req.Response{status: 404, body: %{}}}
      end)

      assert {:error, {:http_error, 404}} = GithubReleases.get_latest_release()
    end

    test "returns error on network failure" do
      stub(Req, :get, fn _url, _opts ->
        {:error, %Req.TransportError{reason: :timeout}}
      end)

      assert {:error, _} = GithubReleases.get_latest_release()
    end
  end

  describe "find_asset/2" do
    @release %{
      "assets" => [
        %{
          "name" => "aod-server-linux-x86_64",
          "url" => "https://api.github.com/repos/jhgaylor/aod-ex/releases/assets/1"
        },
        %{
          "name" => "aod-linux-x86_64",
          "url" => "https://api.github.com/repos/jhgaylor/aod-ex/releases/assets/2"
        }
      ]
    }

    test "returns matching asset" do
      assert {:ok, %{"name" => "aod-server-linux-x86_64"}} =
               GithubReleases.find_asset(@release, "aod-server-linux-x86_64")
    end

    test "returns error when not found" do
      assert {:error, :not_found} = GithubReleases.find_asset(@release, "nonexistent")
    end

    test "returns error when assets missing" do
      assert {:error, :not_found} =
               GithubReleases.find_asset(%{}, "aod-server-linux-x86_64")
    end
  end

  describe "download_asset/2" do
    test "writes response body to dest_path on success" do
      tmp = System.tmp_dir!() <> "/test_download_#{System.unique_integer([:positive])}"

      stub(Req, :get, fn _url, _opts ->
        {:ok, %Req.Response{status: 200, body: "binary content"}}
      end)

      asset = %{"url" => "https://api.github.com/repos/jhgaylor/aod-ex/releases/assets/1"}
      assert :ok = GithubReleases.download_asset(asset, tmp)
      assert File.read!(tmp) == "binary content"

      File.rm(tmp)
    end

    test "returns error on HTTP failure" do
      stub(Req, :get, fn _url, _opts ->
        {:error, %Req.TransportError{reason: :econnrefused}}
      end)

      asset = %{"url" => "https://api.github.com/repos/jhgaylor/aod-ex/releases/assets/1"}
      assert {:error, _} = GithubReleases.download_asset(asset, "/tmp/ignored")
    end
  end
end
