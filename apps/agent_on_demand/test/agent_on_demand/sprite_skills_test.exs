defmodule AgentOnDemand.SpriteSkillsTest do
  use ExUnit.Case, async: true

  alias AgentOnDemand.SpriteSkills

  describe "safe_token!/1" do
    test "passes alphanumerics, dot, underscore, slash, dash" do
      for ok <- [
            "anthropics/skills",
            "frontend-design",
            "claude-code",
            "owner.with.dots/repo",
            "a_b/c",
            "0123",
            "X-Y_Z.0/1-2"
          ] do
        assert SpriteSkills.safe_token!(ok) == ok
      end
    end

    test "rejects shell metacharacters" do
      for bad <- [
            "foo;rm -rf /",
            "foo bar",
            "foo$BAR",
            "foo`whoami`",
            "foo|baz",
            "foo&bar",
            "foo>out",
            "foo<in",
            ~s(foo"baz),
            "foo'baz",
            "foo\\baz",
            "foo\nbar",
            "",
            "foo*"
          ] do
        assert_raise ArgumentError, fn -> SpriteSkills.safe_token!(bad) end
      end
    end
  end
end
