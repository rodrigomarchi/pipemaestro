defmodule PipeMaestro.AuditTest do
  use PipeMaestro.DataCase, async: true

  import PipeMaestro.Fixtures

  alias PipeMaestro.{Audit, Tasks}

  setup do
    workspace = workspace_fixture()
    user = member_fixture(workspace, %{name: "Ana"})
    {runner, _token} = runner_fixture(workspace, user, %{name: "mac"})
    runner = with_directories(runner, [%{"name" => "app", "git" => true}])
    %{workspace: workspace, user: user, runner: runner}
  end

  test "records who did what, newest first, per workspace", ctx do
    pipeline = pipeline_fixture(ctx.workspace, %{"name" => "Fluxo"})
    :ok = Audit.record(ctx.workspace, ctx.user, "pipeline.saved", pipeline, %{"version" => 1})

    {:ok, task} =
      Tasks.create_task(ctx.user, ctx.workspace, %{
        "title" => "Corrigir",
        "prompt" => "p",
        "pipeline_id" => pipeline.id,
        "project_id" => project_fixture(ctx.runner, "app").id
      })

    {:ok, _} = Tasks.cancel_task(task, by: ctx.user)

    actions = ctx.workspace |> Audit.list_events() |> Enum.map(& &1.action)
    assert actions == ["task.canceled", "task.created", "pipeline.saved", "runner.approved"]

    [canceled, created, saved, approved] = Audit.list_events(ctx.workspace)
    assert %{subject_type: "task", subject_name: "Corrigir", actor_user: %{name: "Ana"}} = created
    assert canceled.subject_id == task.id
    assert saved.details == %{"version" => 1}
    assert approved.subject_name == "mac"

    assert Audit.list_events(workspace_fixture()) == []
  end
end
