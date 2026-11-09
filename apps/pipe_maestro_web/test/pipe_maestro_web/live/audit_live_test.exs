defmodule PipeMaestroWeb.AuditLiveTest do
  use PipeMaestroWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  setup :register_and_log_in_member

  test "an admin sees who did what: pipelines saved and removed, runners renamed", ctx do
    pipeline = pipeline_fixture(ctx.workspace, %{"name" => "Meu"})
    runner_fixture(ctx.workspace, ctx.user, %{name: "mac"})

    {:ok, view, _html} =
      live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/pipelines/#{pipeline.id}/edit")

    {:error, {:live_redirect, _}} = view |> form("#pipeline-form") |> render_submit()

    {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/runners")
    view |> element("[data-testid=runner-rename-mac]") |> render_click()
    view |> form("#rename-form", runner: %{name: "mac-mini"}) |> render_submit()

    {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/audit")
    events = view |> element("[data-testid=audit-events]") |> render()
    assert events =~ "Pipeline salvo"
    assert events =~ "Meu"
    assert events =~ "Runner renomeado"
    assert events =~ "mac-mini"
    assert events =~ "Runner aprovado"
    assert events =~ "Ana Lima"
    assert has_element?(view, "[data-testid=sidebar-audit]")
  end

  test "the events are cards, 30 at a time", ctx do
    pipeline = pipeline_fixture(ctx.workspace, %{"name" => "Meu"})

    for n <- 1..31,
        do:
          :ok =
            PipeMaestro.Audit.record(ctx.workspace, ctx.user, "pipeline.saved", pipeline, %{
              "version" => n
            })

    [newest | _] = listed = PipeMaestro.Audit.list_events(ctx.workspace)
    oldest = List.last(listed)

    {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/audit")

    assert has_element?(
             view,
             "[data-testid=audit-events] li[data-testid=audit-event-#{newest.id}]"
           )

    refute has_element?(view, "[data-testid=audit-event-#{oldest.id}]")

    view |> element("[data-testid=audit-load-more]") |> render_click()
    assert has_element?(view, "[data-testid=audit-event-#{oldest.id}]", "Pipeline salvo")
  end

  test "a member cannot see it", %{conn: conn, workspace: workspace} do
    member = member_fixture(workspace)
    conn = log_in_user(conn, member)

    assert {:error, {:live_redirect, %{flash: %{"error" => _}}}} =
             live(conn, ~p"/w/#{workspace.slug}/audit")
  end
end
