defmodule ClaudeControlPlaneWeb.PageController do
  use ClaudeControlPlaneWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
