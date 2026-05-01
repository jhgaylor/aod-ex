defmodule AgentOnDemand.Crypto do
  @moduledoc """
  AES-256-GCM symmetric encryption for secret values at rest.

  Key comes from `Application.fetch_env!(:agent_on_demand, :secrets_key)` —
  a 32-byte binary, set from the SECRETS_KEY env var in runtime.exs.
  """

  @aad "agent_on_demand.secret"

  @spec encrypt(binary()) :: binary()
  def encrypt(plaintext) when is_binary(plaintext) do
    iv = :crypto.strong_rand_bytes(12)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key(), iv, plaintext, @aad, true)

    iv <> tag <> ciphertext
  end

  @spec decrypt(binary()) :: {:ok, binary()} | :error
  def decrypt(<<iv::binary-12, tag::binary-16, ciphertext::binary>>) do
    case :crypto.crypto_one_time_aead(:aes_256_gcm, key(), iv, ciphertext, @aad, tag, false) do
      :error -> :error
      plaintext -> {:ok, plaintext}
    end
  end

  def decrypt(_), do: :error

  defp key do
    case Application.fetch_env!(:agent_on_demand, :secrets_key) do
      <<_::binary-32>> = k -> k
      other -> raise "expected :secrets_key to be 32 bytes, got #{byte_size(other)}"
    end
  end
end
