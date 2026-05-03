defmodule AgentOnDemand.Conversations.ProvisioningEnvFileTest do
  use ExUnit.Case, async: false

  alias AgentOnDemand.Conversations.Provisioning

  describe "render_env_file/1" do
    test "renders KEY=value lines" do
      out = Provisioning.render_env_file([{"FOO", "bar"}, {"BAZ", "qux"}])
      assert out == "FOO=bar\nBAZ=qux\n"
    end

    test "quotes values with whitespace" do
      out = Provisioning.render_env_file([{"GREETING", "hello world"}])
      assert out =~ ~s|GREETING="hello world"|
    end

    test "escapes embedded double quotes" do
      out = Provisioning.render_env_file([{"MSG", ~s|she said "hi"|}])
      assert out =~ ~s|MSG="she said \\"hi\\""|
    end

    test "leaves token-shaped values unquoted (no whitespace, no metacharacters)" do
      out = Provisioning.render_env_file([{"GH", "ghp_abc-def_123"}])
      assert out =~ "GH=ghp_abc-def_123\n"
    end

    test "handles empty list" do
      assert Provisioning.render_env_file([]) == "\n"
    end

    test "quotes values with $ to prevent shell expansion when sourced" do
      out = Provisioning.render_env_file([{"X", "$PATH"}])
      assert out =~ ~s|X="$PATH"|
    end
  end
end
