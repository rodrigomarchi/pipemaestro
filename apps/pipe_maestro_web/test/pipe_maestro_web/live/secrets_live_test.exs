defmodule PipeMaestroWeb.SecretsLiveTest do
  use PipeMaestroWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias PipeMaestro.Secrets

  setup :register_and_log_in_member

  test "an admin adds, replaces and removes secrets, never seeing their values", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/secrets")
    assert has_element?(view, "[data-testid=no-secrets]")

    html =
      view |> form("#secret-form", secret: %{name: "minusculo", value: "x"}) |> render_submit()

    assert html =~ "LETRAS_MAIUSCULAS"

    view
    |> form("#secret-form", secret: %{name: "GRAFANA_TOKEN", value: "glsa_1"})
    |> render_submit()

    assert has_element?(view, "[data-testid=secret-GRAFANA_TOKEN]")
    refute render(view) =~ "glsa_1"
    assert Secrets.env(ctx.workspace) == %{"GRAFANA_TOKEN" => "glsa_1"}

    view |> element("[data-testid=secret-delete-GRAFANA_TOKEN]") |> render_click()
    assert has_element?(view, "[data-testid=no-secrets]")
  end

  test "a member cannot reach them", %{conn: conn, workspace: workspace} do
    conn = log_in_user(conn, member_fixture(workspace))
    assert {:error, {:live_redirect, _}} = live(conn, ~p"/w/#{workspace.slug}/secrets")
  end
end
