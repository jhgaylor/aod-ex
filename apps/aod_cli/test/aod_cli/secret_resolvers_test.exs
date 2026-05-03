defmodule AodCli.SecretResolversTest do
  use ExUnit.Case, async: true

  alias AodCli.SecretResolvers

  describe "for_value/1" do
    test "routes op:// values to OnePassword" do
      assert SecretResolvers.for_value("op://Personal/GitHub/token") ==
               AodCli.OnePassword
    end

    test "routes bws:// values to Bitwarden" do
      assert SecretResolvers.for_value("bws://be8e0ad8-1234-5678-90ab-cdef01234567") ==
               AodCli.Bitwarden
    end

    test "routes infisical:// values to Infisical" do
      assert SecretResolvers.for_value("infisical://abc/prod/DATABASE_URL") ==
               AodCli.Infisical
    end

    test "routes empty-project infisical:/// values to Infisical" do
      assert SecretResolvers.for_value("infisical:///prod/DATABASE_URL") ==
               AodCli.Infisical
    end

    test "returns nil for literal strings" do
      assert SecretResolvers.for_value("ghp_literal_token") == nil
      assert SecretResolvers.for_value("${SOME_VAR}") == nil
    end

    test "returns nil for non-strings" do
      assert SecretResolvers.for_value(nil) == nil
      assert SecretResolvers.for_value(42) == nil
      assert SecretResolvers.for_value(%{}) == nil
    end
  end

  describe "all/0" do
    test "returns the registered resolver modules" do
      all = SecretResolvers.all()
      assert AodCli.OnePassword in all
      assert AodCli.Bitwarden in all
      assert AodCli.Infisical in all
    end
  end
end
