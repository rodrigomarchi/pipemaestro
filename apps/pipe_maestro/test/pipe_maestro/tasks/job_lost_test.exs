defmodule PipeMaestro.Tasks.JobLostTest do
  use PipeMaestro.DataCase, async: true

  import PipeMaestro.Fixtures

  alias PipeMaestro.{Jobs, RunnerTelemetry, Tasks}
  alias PipeMaestro.Jobs.Job
  alias PipeMaestro.Tasks.{StageRun, Task}

  setup do
    workspace = workspace_fixture()
    user = member_fixture(workspace)
    {runner, _token} = runner_fixture(workspace, user)
    runner = with_directories(runner, [%{"name" => "app", "git" => true}])

    %{
      workspace: workspace,
      user: user,
      runner: runner,
      projects: projects_fixture(runner),
      pipeline: pipeline_fixture(workspace)
    }
  end

  defp create_task(ctx) do
    {:ok, task} =
      Tasks.create_task(ctx.user, ctx.workspace, %{
        "title" => "Corrigir o login",
        "prompt" => "O botão de login não responde",
        "pipeline_id" => ctx.pipeline.id,
        "project_id" => ctx.projects["app"].id
      })

    task
  end

  defp reload(ctx, task), do: Tasks.get_task!(ctx.workspace, task.id)

  defp running_run(ctx, task, key \\ "a") do
    Enum.find(reload(ctx, task).stage_runs, &(&1.key == key and &1.status == :running))
  end

  # The runner starts the stage's job and restarts before reporting its end.
  defp lose_current(ctx, task, key \\ "a") do
    assert %StageRun{} = run = running_run(ctx, task, key), "stage #{key} is not running"
    {:ok, _} = Jobs.mark_started(ctx.runner, run.job.id)
    Jobs.reconcile(ctx.runner, [])
    run
  end

  # {attempt, requeue, status} of a stage's runs, in the timeline's order.
  defp timeline(task, key \\ "a") do
    for %StageRun{key: ^key} = run <- task.stage_runs,
        do: {run.attempt, run.requeue, run.status}
  end

  describe "a job lost by a restarted runner" do
    test "is not an attempt: the stage runs again in the same attempt, on the same worktree",
         ctx do
      task = create_task(ctx)
      :ok = Jobs.subscribe({:runner, ctx.runner.id})

      lost = lose_current(ctx, task)
      task = reload(ctx, task)

      assert %Task{status: :running, current_stage: 0} = task
      assert timeline(task) == [{1, 0, :lost}, {1, 1, :running}]

      assert %Job{status: :failed, error: "Perdido: o runner reiniciou" <> _} =
               Jobs.get_job!(ctx.workspace, lost.job.id)

      assert_receive {:job_assign, job}
      assert job.runner_id == ctx.runner.id
      assert job.context["worktree"] == %{"task_id" => task.id, "branch" => task.branch}
      assert job.context["artifact_path"] == lost.job.context["artifact_path"]
    end

    test "the run again keeps the instructions and feedback of the lost one, and its reason",
         ctx do
      task = create_task(ctx)
      lost = lose_current(ctx, task)

      task = reload(ctx, task)
      [lost_run, again] = Enum.filter(task.stage_runs, &(&1.key == "a"))

      assert lost_run.id == lost.id
      assert lost_run.error =~ "runner"
      assert again.instructions == lost.instructions
      assert again.feedback == lost.feedback
      assert again.job.prompt == lost.job.prompt
    end

    test "the gate does not run: the task asks for no analysis", ctx do
      task = create_task(ctx)
      lose_current(ctx, task)

      task = reload(ctx, task)
      assert task.decision_analysis_job_id == nil
      refute Enum.any?(task.stage_runs, &(&1.status == :failed))
    end

    test "is told as an event of the runner", ctx do
      task = create_task(ctx)
      lost = lose_current(ctx, task)

      since = DateTime.add(DateTime.utc_now(), -60)
      job_id = lost.job.id
      task_id = task.id

      assert [%{kind: "job_lost", level: "warning", job_id: ^job_id, task_id: ^task_id}] =
               RunnerTelemetry.events(ctx.runner, since, "connection")
    end

    test "past the limit of losses in one attempt, the task stops for a person, without analysis",
         ctx do
      task = create_task(ctx)

      for _loss <- 1..3, do: lose_current(ctx, task)
      task = reload(ctx, task)
      assert %Task{status: :running} = task
      assert timeline(task) == [{1, 0, :lost}, {1, 1, :lost}, {1, 2, :lost}, {1, 3, :running}]

      lose_current(ctx, task)
      task = reload(ctx, task)

      assert %Task{status: :awaiting_decision} = task
      assert task.decision_reason =~ "Etapa A"
      assert task.decision_reason =~ "interrompida 4 vezes"
      assert task.decision_analysis_job_id == nil
      assert Enum.all?(task.stage_runs, &(&1.status == :lost))
    end

    test "a loss after a failed attempt runs that attempt again, with its feedback", ctx do
      task = create_task(ctx)
      run = running_run(ctx, task)
      {:ok, _} = Jobs.mark_started(ctx.runner, run.job.id)

      {:ok, _} =
        Jobs.finish_job(ctx.runner, run.job.id, %{
          "status" => "failed",
          "exit_code" => 1,
          "error" => "boom"
        })

      second = running_run(ctx, task)
      assert second.attempt == 2
      assert second.feedback

      lose_current(ctx, task)
      task = reload(ctx, task)

      assert timeline(task) == [{1, 0, :failed}, {2, 0, :lost}, {2, 1, :running}]
      assert running_run(ctx, task).feedback == second.feedback
    end

    test "is idempotent: the same loss told twice runs the stage again once", ctx do
      task = create_task(ctx)
      lost = lose_current(ctx, task)

      assert Tasks.job_lost(Jobs.get_job!(ctx.workspace, lost.job.id)) == :ok

      assert timeline(reload(ctx, task)) == [{1, 0, :lost}, {1, 1, :running}]
    end
  end

  describe "a cancel the runner made on its own" do
    test "an end reported as canceled with no one asking counts as lost", ctx do
      task = create_task(ctx)
      run = running_run(ctx, task)
      {:ok, _} = Jobs.mark_started(ctx.runner, run.job.id)

      {:ok, _} = Jobs.finish_job(ctx.runner, run.job.id, %{"status" => "canceled"})
      task = reload(ctx, task)

      assert %Task{status: :running} = task
      assert timeline(task) == [{1, 0, :lost}, {1, 1, :running}]
    end

    test "a cancel someone asked for still cancels the task", ctx do
      task = create_task(ctx)
      run = running_run(ctx, task)
      {:ok, job} = Jobs.mark_started(ctx.runner, run.job.id)
      {:ok, _} = Jobs.request_cancel(job)

      {:ok, _} = Jobs.finish_job(ctx.runner, run.job.id, %{"status" => "canceled"})

      assert %Task{status: :canceled} = reload(ctx, task)
    end
  end

  describe "a stage of a group" do
    setup ctx do
      pipeline =
        pipeline_fixture(ctx.workspace, %{
          "stages" => [
            %{"key" => "impl", "name" => "Implementar", "prompt" => "p"},
            %{"key" => "seg", "name" => "Segurança", "prompt" => "p", "group" => "auditorias"},
            %{"key" => "perf", "name" => "Desempenho", "prompt" => "p", "group" => "auditorias"},
            %{"key" => "fim", "name" => "Consolidar", "prompt" => "p"}
          ]
        })

      %{pipeline: pipeline}
    end

    defp pass(ctx, task, key) do
      run = running_run(ctx, task, key)
      {:ok, _} = Jobs.mark_started(ctx.runner, run.job.id)

      {:ok, _} =
        Jobs.finish_job(ctx.runner, run.job.id, %{
          "status" => "succeeded",
          "exit_code" => 0,
          "structured_output" => %{"status" => "ok", "resumo" => "feito"},
          "artifact" => "# Artefato"
        })
    end

    test "runs again alone, and the group goes on once it passes", ctx do
      task = create_task(ctx)
      pass(ctx, task, "impl")

      perf = running_run(ctx, task, "perf")
      seg = running_run(ctx, task, "seg")
      {:ok, _} = Jobs.mark_started(ctx.runner, perf.job.id)
      {:ok, _} = Jobs.mark_started(ctx.runner, seg.job.id)

      # The runner came back still running perf, but not seg.
      Jobs.reconcile(ctx.runner, [perf.job.id])

      task = reload(ctx, task)
      assert timeline(task, "seg") == [{1, 0, :lost}, {1, 1, :running}]
      assert timeline(task, "perf") == [{1, 0, :running}]

      finish_started(ctx, perf)
      pass(ctx, task, "seg")

      assert %Task{current_stage: 3, status: :running} = reload(ctx, task)
    end

    defp finish_started(ctx, run) do
      {:ok, _} =
        Jobs.finish_job(ctx.runner, run.job.id, %{
          "status" => "succeeded",
          "exit_code" => 0,
          "structured_output" => %{"status" => "ok", "resumo" => "feito"},
          "artifact" => "# Artefato"
        })
    end
  end
end
