defmodule AgentOnDemand.SubstitutionTest do
  use ExUnit.Case, async: true

  alias AgentOnDemand.Substitution

  describe "strings" do
    test "${VAR} substitutes from the vars map" do
      assert {:ok, "Bearer abc"} = Substitution.apply("Bearer ${TOKEN}", %{"TOKEN" => "abc"})
    end

    test "multiple refs in one string" do
      assert {:ok, "abc / xyz / abc"} =
               Substitution.apply("${A} / ${B} / ${A}", %{"A" => "abc", "B" => "xyz"})
    end

    test "$${VAR} survives as literal ${VAR}" do
      assert {:ok, "literal ${TOKEN}"} =
               Substitution.apply("literal $${TOKEN}", %{"TOKEN" => "abc"})
    end

    test "$$ alone becomes literal $" do
      assert {:ok, "$50"} = Substitution.apply("$$50", %{})
    end

    test "lowercase identifiers are not matched (kept literal)" do
      assert {:ok, "${lowercase}"} = Substitution.apply("${lowercase}", %{})
    end

    test "missing single var returns error with the name" do
      assert {:error, {:missing_vars, ["TOKEN"]}} =
               Substitution.apply("${TOKEN}", %{})
    end

    test "deduplicates missing var names" do
      assert {:error, {:missing_vars, ["TOKEN"]}} =
               Substitution.apply("${TOKEN} ${TOKEN}", %{})
    end

    test "string with missing vars is left untouched (not half-substituted)" do
      # `A` is present, `B` is not. We surface the error rather than
      # producing `"abc / ${B}"` which would be confusing.
      assert {:error, {:missing_vars, ["B"]}} =
               Substitution.apply("${A} / ${B}", %{"A" => "abc"})
    end
  end

  describe "recursion" do
    test "walks maps with string keys" do
      input = %{"headers" => %{"Authorization" => "Bearer ${TOKEN}"}}
      vars = %{"TOKEN" => "abc"}

      assert {:ok, %{"headers" => %{"Authorization" => "Bearer abc"}}} =
               Substitution.apply(input, vars)
    end

    test "walks lists" do
      assert {:ok, ["a", "b", "abc"]} =
               Substitution.apply(["a", "b", "${V}"], %{"V" => "abc"})
    end

    test "walks deeply nested mcp_servers shape" do
      input = %{
        "github" => %{
          "type" => "http",
          "url" => "https://api.github.com",
          "headers" => %{"Authorization" => "Bearer ${GITHUB_TOKEN}"}
        },
        "stdio" => %{
          "command" => "node",
          "args" => ["server.js", "--token", "${OTHER_TOKEN}"]
        }
      }

      vars = %{"GITHUB_TOKEN" => "ghp_x", "OTHER_TOKEN" => "ot_y"}

      assert {:ok, out} = Substitution.apply(input, vars)
      assert get_in(out, ["github", "headers", "Authorization"]) == "Bearer ghp_x"
      assert get_in(out, ["stdio", "args"]) == ["server.js", "--token", "ot_y"]
    end

    test "collects missing vars across the whole tree in one pass" do
      input = %{
        "a" => "${A}",
        "b" => ["${B}", %{"c" => "${C}"}]
      }

      assert {:error, {:missing_vars, missing}} = Substitution.apply(input, %{})
      assert missing == ["A", "B", "C"]
    end

    test "non-string leaves pass through untouched" do
      input = %{"timeout" => 30, "verbose" => true, "tag" => nil, "ratio" => 1.5}
      assert {:ok, ^input} = Substitution.apply(input, %{})
    end
  end

  describe "edge cases" do
    test "empty map" do
      assert {:ok, %{}} = Substitution.apply(%{}, %{"X" => "y"})
    end

    test "empty string" do
      assert {:ok, ""} = Substitution.apply("", %{})
    end

    test "$$$${VAR} is literal $${VAR} (no substitution)" do
      # Two `$$` escapes = literal `$$`, then `{VAR}` is literal text.
      assert {:ok, "$${VAR}"} = Substitution.apply("$$$${VAR}", %{"VAR" => "x"})
    end

    test "$$${VAR} is literal $ followed by substituted value" do
      # One `$$` = literal `$`, then `${VAR}` substitutes.
      assert {:ok, "$abc"} = Substitution.apply("$$${VAR}", %{"VAR" => "abc"})
    end
  end
end
