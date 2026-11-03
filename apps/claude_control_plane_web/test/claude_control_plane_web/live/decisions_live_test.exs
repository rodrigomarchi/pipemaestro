defmodule ClaudeControlPlaneWeb.DecisionsLiveTest do
  use ClaudeControlPlaneWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ClaudeControlPlane.{Jobs, Tasks}

  setup :register_and_log_in_member

  setup %{workspace: workspace, user: user} do
    {runner, _token} = runner_fixture(workspace, user, %{name: "mac"})
    runner = with_directories(runner, [%{"name" => "app", "git" => true}])
    %{runner: runner, pipeline: pipeline_fixture(workspace, %{"name" => "Duas etapas"})}
  end

  defp blocked_task(ctx, title) do
    {:ok, task} =
      Tasks.create_task(ctx.user, ctx.workspace, %{
        "title" => title,
        "prompt" => "faça",
        "pipeline_id" => ctx.pipeline.id,
        "runner_id" => ctx.runner.id,
        "directory" => "app"
      })

    job = List.last(Tasks.get_task!(ctx.workspace, task.id).stage_runs).job
    {:ok, _} = Jobs.mark_started(ctx.runner, job.id)

    {:ok, _} =
      Jobs.finish_job(ctx.runner, job.id, %{
        "status" => "succeeded",
        "exit_code" => 0,
        "structured_output" => %{"status" => "bloqueado", "resumo" => "Qual navegador?"}
      })

    Tasks.get_task!(ctx.workspace, task.id)
  end

  test "the menu counts the decisions waiting, live, on any page", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/runners")
    refute has_element?(view, "[data-testid=sidebar-decisions]", "1")

    blocked_task(ctx, "Tela branca")
    assert has_element?(view, "[data-testid=sidebar-decisions]", "1")
  end

  test "any page tells, with a toast and a browser notification, when a task pauses", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/runners")

    task = blocked_task(ctx, "Tela branca")
    path = "/w/#{ctx.workspace.slug}/tasks/#{task.id}"

    assert_push_event(view, "notify", %{title: "Tela branca aguarda decisão", url: ^path})
    assert render(view) =~ "Tela branca aguarda decisão"
  end

  test "lists what waits for a decision and decides from there", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/decisions")
    assert has_element?(view, "[data-testid=no-decisions]")

    task = blocked_task(ctx, "Tela branca")
    other = blocked_task(ctx, "Login lento")

    assert has_element?(view, "[data-testid=decision-#{task.id}]", "Tela branca")
    assert has_element?(view, "[data-testid=decision-#{task.id}]", "Qual navegador?")
    assert has_element?(view, "[data-testid=decision-#{task.id}]", "Etapa A")

    view
    |> form("[data-testid=decision-form-#{task.id}]", decision: %{instructions: "Safari 17"})
    |> render_submit(%{"action" => "retry"})

    refute has_element?(view, "[data-testid=decision-#{task.id}]")

    assert List.last(Tasks.get_task!(ctx.workspace, task.id).stage_runs).instructions ==
             "Safari 17"

    view
    |> form("[data-testid=decision-form-#{other.id}]")
    |> render_submit(%{"action" => "cancel"})

    assert Tasks.get_task!(ctx.workspace, other.id).status == :canceled
    assert has_element?(view, "[data-testid=no-decisions]")
  end
end
