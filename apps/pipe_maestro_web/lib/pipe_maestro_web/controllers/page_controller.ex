defmodule PipeMaestroWeb.PageController do
  @moduledoc "Public static pages."
  use PipeMaestroWeb, :controller

  alias PipeMaestro.Workspaces.Plan
  alias PipeMaestroWeb.{Docs, LandingShots}

  @doc "The landing page, with the screenshots of the platform, the walkthrough and the everyday examples."
  @spec home(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def home(conn, _params) do
    render(conn, :home,
      page_title: "Da issue ao Pull Request",
      shots: LandingShots.all(),
      walkthrough: LandingShots.walkthrough(),
      examples: Docs.section!("exemplos").pages
    )
  end

  @doc "The plans: during the beta, only Free (ADR 0058)."
  @spec pricing(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def pricing(conn, _params) do
    render(conn, :pricing, page_title: "Planos", limits: Plan.free_beta())
  end
end
