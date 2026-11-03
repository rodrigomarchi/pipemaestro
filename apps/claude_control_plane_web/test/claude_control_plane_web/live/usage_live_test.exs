defmodule ClaudeControlPlaneWeb.UsageLiveTest do
  use ClaudeControlPlaneWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ClaudeControlPlane.Jobs

  setup :register_and_log_in_member

  test "shows cost and runs by day, pipeline, runner, person and stage", %{
    conn: conn,
    workspace: workspace,
    user: user
  } do
    {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/usage")
    assert has_element?(view, "[data-testid=usage-total-cost]", "US$ 0.0000")
    assert has_element?(view, "[data-testid=usage-empty]")

    {runner, _token} = runner_fixture(workspace, user, %{name: "mac"})
    job = job_fixture(runner, user)
    {:ok, _} = Jobs.mark_started(runner, job.id)

    {:ok, _} =
      Jobs.finish_job(runner, job.id, %{
        "status" => "succeeded",
        "cost_usd" => 1.25,
        "duration_ms" => 65_000
      })

    {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/usage")
    assert has_element?(view, "[data-testid=usage-total-cost]", "US$ 1.2500")
    assert has_element?(view, "[data-testid=usage-total-runs]", "1")
    assert has_element?(view, "[data-testid=usage-total-time]", "1 min 05 s")
    assert has_element?(view, "[data-testid=usage-by-runner]", "mac")
    assert has_element?(view, "[data-testid=usage-by-person]", user.name)
    assert has_element?(view, "[data-testid=usage-day-#{Date.utc_today()}]")

    view |> form("#usage-period", period: %{days: "30"}) |> render_change()
    assert has_element?(view, "[data-testid=usage-period-label]", "30 dias")
    assert has_element?(view, "[data-testid=sidebar-usage]")
  end
end
