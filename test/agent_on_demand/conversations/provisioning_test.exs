defmodule AgentOnDemand.Conversations.ProvisioningTest do
  use ExUnit.Case, async: false

  alias AgentOnDemand.Conversations.Provisioning

  describe "shell_quote/1" do
    test "wraps in single quotes" do
      assert Provisioning.shell_quote("hello") == "'hello'"
    end

    test "escapes embedded single quotes" do
      # ' inside the value becomes '\''
      assert Provisioning.shell_quote("don't") == "'don'\\''t'"
    end

    test "preserves double quotes and dollar signs untouched" do
      assert Provisioning.shell_quote("\"$VAR\"") == "'\"$VAR\"'"
    end

    test "handles empty string" do
      assert Provisioning.shell_quote("") == "''"
    end
  end

  describe "build_apt_commands/1" do
    test "returns [] for an empty list" do
      assert Provisioning.build_apt_commands([]) == []
    end

    test "renders one update + install command for n packages" do
      assert [cmd] = Provisioning.build_apt_commands(["jq", "ripgrep"])
      assert cmd =~ "apt-get update"
      assert cmd =~ "apt-get install"
      assert cmd =~ "'jq'"
      assert cmd =~ "'ripgrep'"
    end

    test "filters non-binary entries silently" do
      assert [cmd] = Provisioning.build_apt_commands([:bad, "ok", 7])
      assert cmd =~ "'ok'"
      refute cmd =~ "bad"
      refute cmd =~ "7"
    end

    test "returns [] when all entries are non-binary" do
      assert Provisioning.build_apt_commands([:foo, 1, nil]) == []
    end
  end

  describe "build_npm_commands/1" do
    test "renders one global install command" do
      assert [cmd] = Provisioning.build_npm_commands(["typescript", "@anthropic-ai/sdk"])
      assert cmd =~ "npm install -g"
      assert cmd =~ "'typescript'"
      assert cmd =~ "'@anthropic-ai/sdk'"
    end

    test "[] for empty input" do
      assert Provisioning.build_npm_commands([]) == []
    end
  end

  describe "build_package_commands/1" do
    test "combines apt + npm in order" do
      cmds =
        Provisioning.build_package_commands(%{
          "apt" => ["jq"],
          "npm" => ["typescript"]
        })

      assert length(cmds) == 2
      assert Enum.at(cmds, 0) =~ "apt-get"
      assert Enum.at(cmds, 1) =~ "npm install"
    end

    test "ignores unknown package types" do
      cmds = Provisioning.build_package_commands(%{"yum" => ["whatever"]})
      assert cmds == []
    end

    test "[] for empty map" do
      assert Provisioning.build_package_commands(%{}) == []
    end

    test "[] for non-map input" do
      assert Provisioning.build_package_commands(nil) == []
      assert Provisioning.build_package_commands("nope") == []
    end
  end

  describe "rewrite_https_with_token/2" do
    test "rewrites https URL with token" do
      assert Provisioning.rewrite_https_with_token(
               "https://github.com/foo/bar",
               "ghp_abc"
             ) ==
               "https://x-access-token:ghp_abc@github.com/foo/bar"
    end

    test "passes non-https URL through" do
      assert Provisioning.rewrite_https_with_token(
               "git@github.com:foo/bar",
               "ghp_abc"
             ) == "git@github.com:foo/bar"
    end
  end

  describe "inject_token/3" do
    test "passes URL through when secret_key is nil/empty" do
      url = "https://github.com/foo/bar"
      assert Provisioning.inject_token(url, nil, %{}) == url
      assert Provisioning.inject_token(url, "", %{"GH" => "tok"}) == url
    end

    test "passes URL through when secret is missing or empty" do
      url = "https://github.com/foo/bar"
      assert Provisioning.inject_token(url, "GH", %{}) == url
      assert Provisioning.inject_token(url, "GH", %{"GH" => ""}) == url
    end

    test "rewrites with the resolved token" do
      url = "https://github.com/foo/bar"

      assert Provisioning.inject_token(url, "GH", %{"GH" => "ghp_abc"}) ==
               "https://x-access-token:ghp_abc@github.com/foo/bar"
    end
  end

  describe "scrub_token/1" do
    test "redacts token from URL" do
      input =
        "Cloning into 'foo'... fatal: https://x-access-token:ghp_secret@github.com/foo/bar denied"

      out = Provisioning.scrub_token(input)
      refute out =~ "ghp_secret"
      assert out =~ "x-access-token:***@github.com/foo/bar"
    end

    test "passes strings without tokens through unchanged" do
      assert Provisioning.scrub_token("normal output") == "normal output"
    end

    test "redacts every occurrence" do
      input =
        "https://x-access-token:a@github.com/x https://x-access-token:b@github.com/y"

      out = Provisioning.scrub_token(input)
      refute out =~ "a@github"
      refute out =~ "b@github"
      assert out =~ "x-access-token:***@github.com/x"
      assert out =~ "x-access-token:***@github.com/y"
    end

    test "is a no-op on non-binary input" do
      assert Provisioning.scrub_token(:atom) == :atom
    end
  end
end
