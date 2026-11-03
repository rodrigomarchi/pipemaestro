defmodule ClaudeControlPlaneWeb.PageControllerTest do
  use ClaudeControlPlaneWeb.ConnCase, async: true

  test "GET / renders the landing page", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)

    assert html =~ "Da issue ao Pull Request"
    assert html =~ ~s(id="como-funciona")
    assert html =~ ~s(href="/login")
  end
end

defmodule ClaudeControlPlaneWeb.HealthControllerTest do
  use ClaudeControlPlaneWeb.ConnCase, async: true

  test "GET /healthz answers ok", %{conn: conn} do
    assert conn |> get(~p"/healthz") |> text_response(200) == "ok"
  end
end
