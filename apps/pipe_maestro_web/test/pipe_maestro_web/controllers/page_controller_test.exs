defmodule PipeMaestroWeb.PageControllerTest do
  use PipeMaestroWeb.ConnCase, async: true

  test "GET / renders the landing page", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)

    assert html =~ "Da issue ao Pull Request"
    assert html =~ ~s(id="como-funciona")
    assert html =~ ~s(href="/login")
  end

  test "the landing page explains the platform simply and in diagrams", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)

    assert html =~ "Explicado como para uma criança"
    for step <- 1..6, do: assert(html =~ ~s(data-testid="kid-step-#{step}"))

    for diagram <- ~w(hero-journey diagram-pipeline diagram-architecture diagram-stage),
        do: assert(html =~ ~s(data-testid="#{diagram}"))
  end
end

defmodule PipeMaestroWeb.HealthControllerTest do
  use PipeMaestroWeb.ConnCase, async: true

  test "GET /healthz answers ok", %{conn: conn} do
    assert conn |> get(~p"/healthz") |> text_response(200) == "ok"
  end
end
