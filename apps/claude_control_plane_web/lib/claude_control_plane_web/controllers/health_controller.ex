defmodule ClaudeControlPlaneWeb.HealthController do
  @moduledoc """
  Liveness for load balancers and for the e2e suite, which waits on it before
  starting. Answers without touching the database.
  """
  use ClaudeControlPlaneWeb, :controller

  @doc "Answers 200 while the endpoint is serving."
  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params), do: text(conn, "ok")
end
