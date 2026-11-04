defmodule PipeMaestroWeb.CacheBodyReader do
  @moduledoc """
  Reads a request's body for `Plug.Parsers` and keeps a copy in
  `conn.assigns.raw_body`, where a webhook checks the sender's signature over
  the exact bytes received.
  """

  @doc "Reads (part of) the body, keeping what was read."
  @spec read_body(Plug.Conn.t(), keyword()) ::
          {:ok | :more, binary(), Plug.Conn.t()} | {:error, term()}
  def read_body(conn, opts) do
    with {status, body, conn} when status in [:ok, :more] <- Plug.Conn.read_body(conn, opts) do
      raw = (conn.assigns[:raw_body] || "") <> body
      {status, body, Plug.Conn.assign(conn, :raw_body, raw)}
    end
  end
end
