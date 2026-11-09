defmodule PipeMaestroWeb.PullRequestsLiveTest do
  use PipeMaestroWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias PipeMaestro.{Jobs, Tasks}

  setup :register_and_log_in_member

  test "a task from an issue gets its PR, shown on the task and in Pull requests", ctx do
    {runner, _token} = runner_fixture(ctx.workspace, ctx.user, %{name: "mac"})
    runner = with_directories(runner, [%{"name" => "app", "git" => true}])
    pipeline = pipeline_fixture(ctx.workspace, %{"name" => "Com PR", "delivery" => "pr"})

    {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/pull-requests")
    assert has_element?(view, "[data-testid=no-pull-requests]")

    {:ok, task} =
      Tasks.create_task(ctx.user, ctx.workspace, %{
        "title" => "Corrigir login",
        "prompt" => "p",
        "pipeline_id" => pipeline.id,
        "project_id" => project_on(runner, "app").id,
        "issue_url" => "https://github.com/acme/app/issues/42"
      })

    job = List.last(Tasks.get_task!(ctx.workspace, task.id).stage_runs).job
    {:ok, _} = Jobs.mark_started(runner, job.id)

    {:ok, _} =
      Jobs.finish_job(runner, job.id, %{
        "status" => "succeeded",
        "exit_code" => 0,
        "cost_usd" => 0.75,
        "structured_output" => %{"status" => "ok", "resumo" => "a"},
        "artifact" => "# a",
        "delivery" => %{
          "commit" => "0123456789abcdef0123456789abcdef01234567",
          "pushed" => true,
          "pr_url" => "https://github.com/acme/app/pull/7"
        }
      })

    {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/tasks/#{task.id}?no=entrega")
    pr = "[href='https://github.com/acme/app/pull/7']"
    assert has_element?(view, "[data-testid=task-overview-pr]#{pr}")
    view |> element("[data-testid=task-node-tab-merge]") |> render_click()
    assert has_element?(view, "[data-testid=task-pr]#{pr}")

    {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/tasks/#{task.id}?no=entrada")
    view |> element("[data-testid=task-node-tab-projeto]") |> render_click()

    assert has_element?(
             view,
             "[data-testid=task-issue][href='https://github.com/acme/app/issues/42']"
           )

    view |> element("[data-testid=task-stage-a]") |> render_click()
    assert has_element?(view, "[data-testid=stage-run-commit-a-1]", "0123456")

    {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/pull-requests")
    assert has_element?(view, "[data-testid=pull-request-#{task.id}]", "Corrigir login")
    assert has_element?(view, "[data-testid=pull-request-#{task.id}]", "pull/7")
    assert has_element?(view, "[data-testid=pull-request-cost-#{task.id}]", "US$ 0.75")
    assert has_element?(view, "[data-testid=pull-request-project-#{task.id}]", "app")
  end
end
