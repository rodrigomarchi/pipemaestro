defmodule PipeMaestroWeb.UsageLiveTest do
  use PipeMaestroWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias PipeMaestro.Jobs

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
        "duration_ms" => 65_000,
        "usage" => %{
          "fresh_input" => 500,
          "cache_read" => 9_000,
          "cache_creation" => 500,
          "output" => 2_000
        },
        "model_usage" => %{"claude-sonnet-5-5" => %{"output" => 2_000, "cost_usd" => 1.25}},
        "permission_denials" => [%{"tool_name" => "Bash"}]
      })

    {:ok, _} =
      Jobs.record_telemetry(runner, job.id, [
        %{
          "name" => "api_request",
          "at" => "2026-11-03T12:00:00Z",
          "attrs" => %{"duration_ms" => 3_000, "ttft_ms" => 800}
        },
        %{
          "name" => "tool_result",
          "at" => "2026-11-03T12:00:01Z",
          "attrs" => %{"tool_name" => "Bash", "success" => false, "duration_ms" => 400}
        }
      ])

    {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/usage")
    assert has_element?(view, "[data-testid=usage-total-cost]", "US$ 1.2500")
    assert has_element?(view, "[data-testid=usage-total-runs]", "1")
    assert has_element?(view, "[data-testid=usage-total-time]", "1 min 05 s")
    assert has_element?(view, "[data-testid=usage-total-tokens]", "12.0k")

    # How the agent worked, consolidated.
    assert has_element?(view, "[data-testid=usage-agent-cache-hit]", "90%")
    assert has_element?(view, "[data-testid=usage-agent-api]", "1 requisição")
    assert has_element?(view, "[data-testid=usage-agent-denials]", "1")
    assert has_element?(view, "[data-testid=usage-agent-model-claude-sonnet-5-5]", "1.2500")
    assert has_element?(view, "[data-testid=usage-agent-tool-errors-Bash]", "1")
    assert has_element?(view, "[data-testid=usage-by-runner]", "mac")
    assert has_element?(view, "[data-testid=usage-by-person]", user.name)
    assert has_element?(view, "[data-testid=usage-day-#{Date.utc_today()}]")

    view |> form("#usage-period", period: %{days: "30"}) |> render_change()
    assert has_element?(view, "[data-testid=usage-period-label]", "30 dias")
    assert has_element?(view, "[data-testid=sidebar-usage]")
  end
end
