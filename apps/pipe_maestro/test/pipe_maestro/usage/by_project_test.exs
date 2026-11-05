defmodule PipeMaestro.Usage.ByProjectTest do
  use PipeMaestro.DataCase, async: true

  import PipeMaestro.Fixtures

  alias PipeMaestro.{Jobs, Projects, Repo, Runners, Tasks, Usage}
  alias PipeMaestro.Jobs.Job

  setup do
    workspace = workspace_fixture()
    user = member_fixture(workspace, %{name: "Ana"})
    {runner, _token} = runner_fixture(workspace, user, %{name: "mac"})

    {:ok, runner} =
      Runners.record_hello(
        runner,
        hello_fixture(%{
          directories: [%{"name" => "app", "git" => true}, %{"name" => "site", "git" => true}],
          capabilities: ["scratch"]
        })
      )

    {:ok, app} =
      Projects.create_project(workspace, %{
        "name" => "App",
        "runner_id" => runner.id,
        "directory" => "app"
      })

    {:ok, site} =
      Projects.create_project(workspace, %{
        "name" => "Site",
        "runner_id" => runner.id,
        "directory" => "site"
      })

    %{
      workspace: workspace,
      user: user,
      runner: runner,
      app: app,
      site: site,
      pipeline: pipeline_fixture(workspace)
    }
  end

  defp finish(ctx, job, cost) do
    {:ok, _} = Jobs.mark_started(ctx.runner, job.id)

    {:ok, _} =
      Jobs.finish_job(ctx.runner, job.id, %{
        "status" => "succeeded",
        "cost_usd" => cost,
        "structured_output" => %{"status" => "ok", "resumo" => "ok"},
        "artifact" => "# a"
      })
  end

  test "groups cost by project, the jobs from before projects as \"sem projeto\"", ctx do
    {:ok, task} =
      Tasks.create_task(ctx.user, ctx.workspace, %{
        "title" => "T",
        "prompt" => "p",
        "pipeline_id" => ctx.pipeline.id,
        "project_id" => ctx.app.id
      })

    [stage_run | _] = Tasks.get_task!(ctx.workspace, task.id).stage_runs
    finish(ctx, stage_run.job, 0.5)

    {:ok, solo} =
      Jobs.create_job(ctx.user, ctx.workspace, %{"prompt" => "x", "project_id" => ctx.site.id})

    finish(ctx, solo, 0.25)

    legacy =
      Repo.insert!(%Job{
        workspace_id: ctx.workspace.id,
        runner_id: ctx.runner.id,
        created_by_user_id: ctx.user.id,
        prompt: "antigo",
        context: %{}
      })

    finish(ctx, legacy, 2)

    since = DateTime.add(DateTime.utc_now(), -7, :day)
    report = Usage.report(ctx.workspace, since)

    assert [
             %{name: "sem projeto", runs: 1} = none,
             %{name: "App", runs: 1} = app,
             %{name: "Site", runs: 1}
           ] = report.by_project

    assert Decimal.equal?(none.cost_usd, Decimal.new("2"))
    assert Decimal.equal?(app.cost_usd, Decimal.new("0.5"))

    only = Usage.report(ctx.workspace, since, %{"project_id" => ctx.app.id})
    assert only.total.runs == 1
    assert [%{name: "App"}] = only.by_project
  end
end
