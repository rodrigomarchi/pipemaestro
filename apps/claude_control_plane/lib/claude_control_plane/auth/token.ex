defmodule ClaudeControlPlane.Auth.Token do
  @moduledoc """
  Session token generation. The raw token goes to the browser session; only
  its SHA-256 hash is stored, so a database read never yields a usable token.
  """

  @rand_size 32

  @doc "A new random token and the hash to persist."
  @spec generate() :: {binary(), binary()}
  def generate do
    token = :crypto.strong_rand_bytes(@rand_size)
    {token, hash(token)}
  end

  @doc "The stored form of `token`."
  @spec hash(binary()) :: binary()
  def hash(token), do: :crypto.hash(:sha256, token)
end
