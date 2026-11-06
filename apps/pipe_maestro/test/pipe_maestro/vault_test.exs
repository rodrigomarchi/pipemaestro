defmodule PipeMaestro.VaultTest do
  use ExUnit.Case, async: true

  alias PipeMaestro.Vault

  test "decrypts what it encrypted, with the same associated data" do
    blob = Vault.encrypt("glsa_123", "pipe_maestro.test")

    refute blob =~ "glsa_123"
    assert Vault.decrypt(blob, "pipe_maestro.test") == {:ok, "glsa_123"}
  end

  test "encrypting twice gives different blobs" do
    refute Vault.encrypt("x", "a") == Vault.encrypt("x", "a")
  end

  test "refuses other associated data, a tampered blob and garbage" do
    blob = Vault.encrypt("glsa_123", "pipe_maestro.test")
    <<head::binary-28, byte, rest::binary>> = blob

    assert Vault.decrypt(blob, "pipe_maestro.other") == :error
    assert Vault.decrypt(head <> <<Bitwise.bxor(byte, 1)>> <> rest, "pipe_maestro.test") == :error
    assert Vault.decrypt("curto", "pipe_maestro.test") == :error
  end

  test "keeps a map through encrypt_term and decrypt_term" do
    term = %{"access_token" => "a", "nested" => %{"expires_at" => "2026-11-06T12:00:00Z"}}
    blob = Vault.encrypt_term(term, "pipe_maestro.integration")

    assert Vault.decrypt_term(blob, "pipe_maestro.integration") == {:ok, term}
    assert Vault.decrypt_term(blob, "pipe_maestro.secret") == :error
  end
end
