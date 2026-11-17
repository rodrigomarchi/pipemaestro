defmodule PipeMaestroWeb.Plugs.RemoteIp do
  @moduledoc """
  Puts the client's address in `conn.remote_ip` when the request came through
  a local proxy (in production, nginx and HAProxy on the same host, ADR 0058).
  The rate limits (`PipeMaestroWeb.RateLimit`) count per address, so without
  this every request would count as the proxy's.

  Only a peer on a loopback or private address is trusted to say who the
  client is, through `X-Forwarded-For`. The header is read from the right: the
  first address that is not a trusted proxy is the client; what the client
  itself wrote further left is never believed. A request that did not come
  from a trusted peer keeps its own address.
  """
  @behaviour Plug

  import Bitwise

  @impl Plug
  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @impl Plug
  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(%Plug.Conn{remote_ip: peer} = conn, _opts) do
    with true <- trusted?(peer),
         [_ | _] = hops <- forwarded(conn) do
      %{conn | remote_ip: client(hops)}
    else
      _ -> conn
    end
  end

  defp forwarded(conn) do
    conn
    |> Plug.Conn.get_req_header("x-forwarded-for")
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.flat_map(fn value ->
      case value |> String.trim() |> String.to_charlist() |> :inet.parse_strict_address() do
        {:ok, address} -> [address]
        {:error, _} -> []
      end
    end)
  end

  # The nearest hop that is not a trusted proxy; if every hop is one, the first.
  defp client(hops) do
    hops |> Enum.reverse() |> Enum.find(&(not trusted?(&1))) || hd(hops)
  end

  defp trusted?({127, _, _, _}), do: true
  defp trusted?({10, _, _, _}), do: true
  defp trusted?({172, second, _, _}) when second in 16..31, do: true
  defp trusted?({192, 168, _, _}), do: true
  defp trusted?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp trusted?({0, 0, 0, 0, 0, 0xFFFF, high, low}), do: trusted?(ipv4(high, low))
  defp trusted?({first, _, _, _, _, _, _, _}) when (first &&& 0xFE00) == 0xFC00, do: true
  defp trusted?(_address), do: false

  defp ipv4(high, low), do: {high >>> 8, high &&& 0xFF, low >>> 8, low &&& 0xFF}
end
