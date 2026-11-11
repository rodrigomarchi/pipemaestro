defmodule PipeMaestroWeb.DocsController do
  @moduledoc "The public documentation (`PipeMaestroWeb.Docs`): its index and each page."
  use PipeMaestroWeb, :controller

  alias PipeMaestroWeb.Docs

  @doc "Every section of the documentation, with its pages."
  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    render(conn, :index, page_title: "Documentação", sections: Docs.sections())
  end

  @doc "One page of the documentation; an unknown slug is a 404."
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"slug" => slug}) do
    case Docs.fetch(slug) do
      {:ok, page} ->
        {previous, next} = Docs.neighbors(page)

        render(conn, :show,
          page_title: page.title,
          page: page,
          section: Docs.section!(page.section),
          sections: Docs.sections(),
          previous: previous,
          next: next
        )

      :error ->
        raise Phoenix.Router.NoRouteError, conn: conn, router: PipeMaestroWeb.Router
    end
  end
end
