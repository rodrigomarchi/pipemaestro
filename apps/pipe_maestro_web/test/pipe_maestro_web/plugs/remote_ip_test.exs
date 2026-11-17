defmodule PipeMaestroWeb.Plugs.RemoteIpTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias PipeMaestroWeb.Plugs.RemoteIp

  defp call(peer, forwarded) do
    conn = conn(:get, "/") |> Map.put(:remote_ip, peer)

    conn =
      Enum.reduce(List.wrap(forwarded), conn, fn value, conn ->
        Plug.Conn.put_req_header(conn, "x-forwarded-for", value)
      end)

    RemoteIp.call(conn, RemoteIp.init([]))
  end

  test "behind a local proxy, the client is the address the proxy saw" do
    assert call({127, 0, 0, 1}, "203.0.113.7").remote_ip == {203, 0, 113, 7}
  end

  test "an address the client wrote itself, on the left, is not believed" do
    assert call({127, 0, 0, 1}, "198.51.100.1, 203.0.113.7, 10.0.0.2").remote_ip ==
             {203, 0, 113, 7}
  end

  test "a peer that is not a local proxy keeps its own address" do
    assert call({198, 51, 100, 9}, "203.0.113.7").remote_ip == {198, 51, 100, 9}
  end

  test "no header, or nothing readable in it, changes nothing" do
    assert call({127, 0, 0, 1}, []).remote_ip == {127, 0, 0, 1}
    assert call({127, 0, 0, 1}, "lixo, ").remote_ip == {127, 0, 0, 1}
  end

  test "reads IPv6 clients, and a chain of only private hops gives the first of them" do
    assert call({127, 0, 0, 1}, "2001:db8::1").remote_ip == {8193, 3512, 0, 0, 0, 0, 0, 1}
    assert call({10, 0, 0, 5}, "192.168.1.20, 10.0.0.2").remote_ip == {192, 168, 1, 20}
  end
end
