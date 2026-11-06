defmodule PipeMaestroWeb.HealthController do
  @moduledoc """
  Liveness for load balancers and for the e2e suite, which waits on it before
  starting, and the identity of the running build, which a deploy polls to
  know its release went live. Neither touches the database.
  """
  use PipeMaestroWeb, :controller

  alias PipeMaestro.Version

  @doc "Answers 200 while the endpoint is serving."
  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params), do: text(conn, "ok")

  @doc """
  The control plane's version (`PipeMaestro.Version`), the runner's version it
  requires, and the release it runs from: `scripts/deploy.sh` stamps the release with the commit it built.
  """
  @spec version(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def version(conn, _params) do
    json(conn, %{
      version: Version.version(),
      runner_version: Version.runner_version(),
      release: to_string(Application.spec(:pipe_maestro, :vsn))
    })
  end
end
