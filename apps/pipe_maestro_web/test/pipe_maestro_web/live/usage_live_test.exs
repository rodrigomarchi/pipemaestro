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

    view |> form("#usage-period", period: %{days: "90"}) |> render_change()
    assert has_element?(view, "[data-testid=usage-period-label]", "90 dias")

    # A job sent on its own has its own origin.
    assert has_element?(view, "[data-testid=usage-by-origin-standalone]", "US$ 1.2500")
  end

  test "by origin, by pipeline, the accounts' limits and what else the agent did", %{
    conn: conn,
    workspace: workspace,
    user: user
  } do
    {runner, _token} = runner_fixture(workspace, user, %{name: "mac"})
    runner = with_directories(runner, [%{"name" => "app", "git" => true}])
    pipeline = pipeline_fixture(workspace, %{"name" => "Entrega"})

    {:ok, task} =
      PipeMaestro.Tasks.create_task(user, workspace, %{
        "title" => "T",
        "prompt" => "p",
        "pipeline_id" => pipeline.id,
        "project_id" => project_on(runner, "app").id
      })

    stage_job = hd(PipeMaestro.Tasks.get_task!(workspace, task.id).stage_runs).job
    {:ok, _} = Jobs.mark_started(runner, stage_job.id)

    {:ok, _} =
      Jobs.append_event(runner, stage_job.id, %{
        "seq" => 1,
        "type" => "rate_limit",
        "data" => %{"status" => "allowed", "utilization" => %{"five_hour" => 0.92}}
      })

    {:ok, _} =
      Jobs.record_telemetry(runner, stage_job.id, [
        %{
          "name" => "metric:active_time",
          "at" => "2026-11-03T12:00:00Z",
          "attrs" => %{"value" => 30}
        }
      ])

    {:ok, _} = Jobs.finish_job(runner, stage_job.id, %{"status" => "failed", "cost_usd" => 0.5})

    proposal = job_fixture(runner, user)

    proposal
    |> Ecto.Changeset.change(context: %{"proposal" => %{"kind" => "pipeline"}})
    |> PipeMaestro.Repo.update!()

    {:ok, _} = Jobs.mark_started(runner, proposal.id)
    {:ok, _} = Jobs.finish_job(runner, proposal.id, %{"status" => "succeeded", "cost_usd" => 2})

    {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/usage")

    assert has_element?(view, "[data-testid=usage-by-origin-stage]", "US$ 0.5")
    assert has_element?(view, "[data-testid=usage-by-origin-proposal-pipeline]", "Proposta: ")
    assert has_element?(view, "[data-testid=usage-rate-limit-mac-five_hour]", "92%")
    assert has_element?(view, "[data-testid=usage-rate-limit-mac-status]", "perto do limite")
    assert has_element?(view, "[data-testid=usage-agent-active-time]", "30 s")
    assert has_element?(view, "[data-testid=usage-stage-queue-a]")
    refute has_element?(view, "[data-testid=usage-pipeline-diagram]")

    view |> form("#usage-period", period: %{pipeline: "Entrega"}) |> render_change()
    assert has_element?(view, "[data-testid=usage-period-label]", "só do pipeline Entrega")

    # The pipeline, stage by stage, with what each one spent.
    assert has_element?(
             view,
             "[data-testid=usage-pipeline-diagram] [data-testid=diagram-metrics-0]",
             "US$ 0.5"
           )

    assert has_element?(view, "[data-testid=diagram-metrics-0]", "1 falha")
    refute has_element?(view, "[data-testid=diagram-metrics-1]")
    assert has_element?(view, "[data-testid=usage-total-runs]", "1")
    refute has_element?(view, "[data-testid=usage-by-origin-proposal-pipeline]")

    # Anything not offered is ignored.
    view |> form("#usage-period", period: %{pipeline: "", days: "7"}) |> render_change()
    assert has_element?(view, "[data-testid=usage-total-runs]", "2")
  end
end
