defmodule PipeMaestro.Vault do
  @moduledoc """
  Encryption at rest for what the platform must keep but never show back: a
  workspace's secrets (`PipeMaestro.Secrets`) and the credentials of its
  integrations (`PipeMaestro.Integrations`).

  AES-256-GCM with a random 12-byte IV, stored as `iv <> tag <> ciphertext`.
  The key is the SHA-256 of `config :pipe_maestro, PipeMaestro.Secrets, key:`.
  Each kind of value passes its own associated data, so a blob of one kind
  never decrypts as another.
  """

  @doc "Encrypts `plaintext` bound to the associated data `aad`."
  @spec encrypt(binary(), binary()) :: binary()
  def encrypt(plaintext, aad) when is_binary(plaintext) and is_binary(aad) do
    iv = :crypto.strong_rand_bytes(12)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key(), iv, plaintext, aad, true)

    iv <> tag <> ciphertext
  end

  @doc "Decrypts a blob of `encrypt/2` with the same associated data."
  @spec decrypt(binary(), binary()) :: {:ok, binary()} | :error
  def decrypt(<<iv::binary-12, tag::binary-16, ciphertext::binary>>, aad) do
    case :crypto.crypto_one_time_aead(:aes_256_gcm, key(), iv, ciphertext, aad, tag, false) do
      plaintext when is_binary(plaintext) -> {:ok, plaintext}
      :error -> :error
    end
  end

  def decrypt(_blob, _aad), do: :error

  @doc "Encrypts a JSON-encodable term."
  @spec encrypt_term(term(), binary()) :: binary()
  def encrypt_term(term, aad), do: term |> JSON.encode!() |> encrypt(aad)

  @doc "Decrypts a blob of `encrypt_term/2` back into the term."
  @spec decrypt_term(binary(), binary()) :: {:ok, term()} | :error
  def decrypt_term(blob, aad) do
    with {:ok, json} <- decrypt(blob, aad),
         {:ok, term} <- JSON.decode(json) do
      {:ok, term}
    else
      _invalid -> :error
    end
  end

  defp key do
    secret = Application.fetch_env!(:pipe_maestro, PipeMaestro.Secrets)[:key]
    :crypto.hash(:sha256, secret)
  end
end
