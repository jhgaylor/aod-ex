defmodule AgentOnDemand.CryptoTest do
  use ExUnit.Case, async: true

  alias AgentOnDemand.Crypto

  describe "encrypt/decrypt round trip" do
    test "decrypts what was encrypted" do
      plaintext = "ghp_super_secret_token"
      ct = Crypto.encrypt(plaintext)
      assert {:ok, ^plaintext} = Crypto.decrypt(ct)
    end

    test "different ciphertext for same plaintext (random IV)" do
      a = Crypto.encrypt("same")
      b = Crypto.encrypt("same")
      refute a == b
      assert {:ok, "same"} = Crypto.decrypt(a)
      assert {:ok, "same"} = Crypto.decrypt(b)
    end

    test "rejects tampered ciphertext" do
      ct = Crypto.encrypt("hi")
      <<head::binary-12, tag::binary-16, body::binary>> = ct
      flipped_body = :crypto.exor(body, :binary.copy(<<1>>, byte_size(body)))
      tampered = head <> tag <> flipped_body
      assert :error = Crypto.decrypt(tampered)
    end

    test "rejects empty / malformed bytes" do
      assert :error = Crypto.decrypt("")
      assert :error = Crypto.decrypt(<<0, 1, 2>>)
    end

    test "round-trips an empty string" do
      ct = Crypto.encrypt("")
      assert {:ok, ""} = Crypto.decrypt(ct)
    end

    test "round-trips long binary" do
      plaintext = :crypto.strong_rand_bytes(8_192)
      assert {:ok, ^plaintext} = Crypto.decrypt(Crypto.encrypt(plaintext))
    end
  end
end
