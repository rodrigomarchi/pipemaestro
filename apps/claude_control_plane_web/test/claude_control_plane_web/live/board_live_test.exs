defmodule ClaudeControlPlaneWeb.BoardLiveTest do
  use ClaudeControlPlaneWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ClaudeControlPlaneWeb.Demo

  test "renders every stage with its tasks", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/app")

    for stage <- Demo.stages(), do: assert(html =~ stage.name)
    for task <- Demo.tasks(), do: assert(has_element?(view, "#task-#{task.id}"))
  end

  test "lists runners and pending decisions", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/app")

    for runner <- Demo.runners(), do: assert(has_element?(view, "#runner-#{runner.name}"))
    for decision <- Demo.decisions(), do: assert(has_element?(view, "#decision-#{decision.id}"))
  end

  test "deciding removes the decision and confirms it", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/app")
    [decision | _] = Demo.decisions()
    [option | _] = decision.options

    view
    |> element("#decision-#{decision.id} button", option)
    |> render_click()

    refute has_element?(view, "#decision-#{decision.id}")
    assert render(view) =~ "Decisão registrada: #{option}"
  end

  test "shows the empty state once every decision is taken", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/app")

    for decision <- Demo.decisions() do
      view |> element("#decision-#{decision.id} button", hd(decision.options)) |> render_click()
    end

    assert render(view) =~ "Nenhuma decisão pendente"
  end

  test "explains where new tasks come from", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/app")

    assert view |> element("button", "Nova tarefa") |> render_click() =~ "issues do GitHub"
  end
end
