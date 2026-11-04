defmodule PipeMaestroWeb.PageController do
  @moduledoc "Public static pages."
  use PipeMaestroWeb, :controller

  alias PipeMaestroWeb.LandingShots

  @doc "The landing page, with the screenshots of the platform."
  @spec home(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def home(conn, _params) do
    render(conn, :home, page_title: "Da issue ao Pull Request", shots: LandingShots.all())
  end
end
