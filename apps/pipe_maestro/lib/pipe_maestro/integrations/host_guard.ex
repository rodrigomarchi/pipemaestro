defmodule PipeMaestro.Integrations.HostGuard do
  @moduledoc """
  Keeps a connection's address from pointing the platform at its own
  network: a host that resolves to a private, loopback, link-local or
  shared address is refused, checked on every request (a name may resolve
  elsewhere later). A self-hosted platform next to its git host turns this
  off with `config :pipe_maestro, PipeMaestro.Integrations,
  allow_private_hosts: true` (`INTEGRATIONS_ALLOW_PRIVATE_HOSTS=true`).
  """

  import Bitwise

  @doc "Whether the platform may call hosts on private networks."
  @spec private_allowed?() :: boolean()
  def private_allowed?,
    do:
      Application.get_env(:pipe_maestro, PipeMaestro.Integrations, [])[:allow_private_hosts] ==
        true

  @doc "`:ok` when the platform may call `url`; otherwise why not."
  @spec check(String.t()) :: :ok | {:error, String.t()}
  def check(url) do
    with false <- private_allowed?(),
         %URI{host: host} when is_binary(host) <- URI.parse(url) do
      if Enum.any?(addresses(host), &private?/1),
        do: {:error, "o endereço #{host} é de uma rede interna"},
        else: :ok
    else
      true -> :ok
      _no_host -> {:error, "endereço inválido"}
    end
  end

  defp addresses(host) do
    host = String.to_charlist(host)

    case :inet.parse_address(host) do
      {:ok, address} ->
        [address]

      {:error, _name} ->
        for family <- [:inet, :inet6],
            {:ok, found} <- [:inet.getaddrs(host, family)],
            address <- found,
            do: address
    end
  end

  @doc "Whether an IP address is private, loopback, link-local or otherwise internal."
  @spec private?(:inet.ip_address()) :: boolean()
  def private?({10, _, _, _}), do: true
  def private?({127, _, _, _}), do: true
  def private?({0, _, _, _}), do: true
  def private?({169, 254, _, _}), do: true
  def private?({172, b, _, _}) when b in 16..31, do: true
  def private?({192, 168, _, _}), do: true
  def private?({100, b, _, _}) when b in 64..127, do: true
  def private?({0, 0, 0, 0, 0, 0, 0, a}) when a in [0, 1], do: true
  def private?({a, _, _, _, _, _, _, _}) when (a &&& 0xFE00) == 0xFC00, do: true
  def private?({a, _, _, _, _, _, _, _}) when (a &&& 0xFFC0) == 0xFE80, do: true

  def private?({0, 0, 0, 0, 0, 0xFFFF, high, low}),
    do: private?({high >>> 8, high &&& 0xFF, low >>> 8, low &&& 0xFF})

  def private?(_address), do: false
end
