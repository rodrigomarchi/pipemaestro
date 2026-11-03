defmodule ClaudeControlPlane.UsageTest do
  use ClaudeControlPlane.DataCase, async: true

  import ClaudeControlPlane.Fixtures

  alias ClaudeControlPlane.{Jobs, Tasks, Usage}

  setup do
    workspace = workspace_fixture()
    user = member_fixture(workspace, %{name: "Ana"})
    {runner, _token} = runner_fixture(workspace, user, %{name: "mac"})
    runner = with_directories(runner, [%{"name" => "app", "git" => true}])
    pipeline = pipeline_fixture(workspace, %{"name" => "Duas etapas"})
    %{workspace: workspace, user: user, runner: runner, pipeline: pipeline}
  end

  defp run(ctx, task, report) do
    task = Tasks.get_task!(ctx.workspace, task.id)
    job = Enum.find(task.stage_runs, &(&1.status == :running)).job
    {:ok, _} = Jobs.mark_started(ctx.runner, job.id)

    {:ok, _} =
      Jobs.finish_job(
        ctx.runner,
        job.id,
        Map.merge(
          %{
            "status" => "succeeded",
            "exit_code" => 0,
            "structured_output" => %{"status" => "ok", "resumo" => "ok"},
            "artifact" => "# a",
            "cost_usd" => 0.5,
            "duration_ms" => 1_000
          },
          report
        )
      )
  end

  test "sums cost, runs and time by pipeline, runner, person, stage and day", ctx do
    {:ok, task} =
      Tasks.create_task(ctx.user, ctx.workspace, %{
        "title" => "T",
        "prompt" => "p",
        "pipeline_id" => ctx.pipeline.id,
        "runner_id" => ctx.runner.id,
        "directory" => "app"
      })

    run(ctx, task, %{"status" => "failed", "exit_code" => 1, "cost_usd" => 0.25})
    run(ctx, task, %{})
    {:ok, _} = Tasks.cancel_task(task)
    _solo = job_fixture(ctx.runner, ctx.user)

    report = Usage.report(ctx.workspace, DateTime.add(DateTime.utc_now(), -7, :day))

    assert Decimal.equal?(report.total.cost_usd, Decimal.new("0.75"))
    assert report.total.runs == 2
    assert report.total.duration_ms == 2_000

    assert [%{name: "Duas etapas", runs: 2, tasks: 1} = by_pipeline] = report.by_pipeline
    assert Decimal.equal?(by_pipeline.cost_usd, Decimal.new("0.75"))
    assert [%{name: "mac", runs: 2}] = report.by_runner
    assert [%{name: "Ana", runs: 2}] = report.by_person

    assert [%{stage: "a", runs: 2, failed: 1}] =
             Enum.filter(report.by_stage, &(&1.pipeline == "Duas etapas"))

    assert [%{date: date, runs: 2}] = report.by_day
    assert date == Date.utc_today()

    assert Usage.report(workspace_fixture(), DateTime.add(DateTime.utc_now(), -7, :day)).total.runs ==
             0
  end
end
