defmodule ClaudeControlPlaneWeb.PageController do
  @moduledoc "Public static pages."
  use ClaudeControlPlaneWeb, :controller

  @doc "The landing page."
  @spec home(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def home(conn, _params) do
    render(conn, :home, page_title: "Da issue ao Pull Request")
  end
end
