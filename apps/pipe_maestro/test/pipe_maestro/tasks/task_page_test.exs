defmodule PipeMaestro.Tasks.TaskPageTest do
  @moduledoc """
  What the task's page reads: the task in a light shape, enough for its
  pipeline and actions, and one stage's attempts in full, for its panel.
  """
  use PipeMaestro.DataCase, async: true

  import PipeMaestro.Fixtures

  alias PipeMaestro.{Jobs, Tasks}
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

  # Plays the runner: starts the task's current job and reports its end.
  defp run_current(ctx, task, report \\ %{}) do
    task = Tasks.get_task!(ctx.workspace, task.id)
    job = List.last(task.stage_runs).job
    {:ok, _} = Jobs.mark_started(ctx.runner, job.id)

    payload =
      Map.merge(
        %{
          "status" => "succeeded",
          "exit_code" => 0,
          "result" => "resposta completa de #{job.id}",
          "structured_output" => %{"status" => "ok", "resumo" => "feito"},
          "artifact" => "# Artefato",
          "workdir" => "/w/worktrees/#{task.id}",
          "cost_usd" => 0.5,
          "duration_ms" => 61_000
        },
        report
      )

    {:ok, _job} = Jobs.finish_job(ctx.runner, job.id, payload)
    Tasks.get_task!(ctx.workspace, task.id)
  end

  describe "get_task_overview!/2" do
    test "the attempts in order, with what the pipeline shows and nothing of their content",
         ctx do
      task = create_task(ctx)
      _task = run_current(ctx, task)

      overview = Tasks.get_task_overview!(ctx.workspace, task.id)

      assert %Task{id: id, title: "Corrigir o login"} = overview
      assert id == task.id
      assert overview.runner.id == ctx.runner.id
      assert overview.created_by_user.id == ctx.user.id

      assert [%StageRun{key: "a", attempt: 1} = a, %StageRun{key: "b", attempt: 1} = b] =
               overview.stage_runs

      assert a.status == :passed
      assert b.status == :running

      # What a node shows: the job's status, cost and duration.
      assert %Job{status: :succeeded, duration_ms: 61_000} = a.job
      assert Decimal.equal?(a.job.cost_usd, Decimal.new("0.5"))
      assert %Job{status: :queued} = b.job

      # Nothing the page renders only in a stage's panel.
      assert is_nil(a.artifact)
      assert is_nil(a.structured_output)
      assert is_nil(a.summary)
      assert is_nil(a.job.result)
      assert is_nil(a.job.prompt)
      assert is_nil(a.job.stderr)
      assert is_nil(a.job.structured_output)
      assert is_nil(a.job.artifact)
      assert is_nil(a.job.insights)
    end

    test "reads the same states as the full task", ctx do
      task = create_task(ctx)
      task = run_current(ctx, task, %{"structured_output" => %{"status" => "bloqueado"}})

      overview = Tasks.get_task_overview!(ctx.workspace, task.id)

      assert overview.status == task.status
      assert overview.current_stage == task.current_stage
      assert overview.decision_reason == task.decision_reason

      assert Enum.map(overview.stage_runs, &{&1.id, &1.status}) ==
               Enum.map(task.stage_runs, &{&1.id, &1.status})
    end

    test "only of the workspace", ctx do
      task = create_task(ctx)
      other = workspace_fixture()

      assert_raise Ecto.NoResultsError, fn -> Tasks.get_task_overview!(other, task.id) end
    end
  end

  describe "stage_attempts/2" do
    test "one stage's attempts, in order, with their jobs in full", ctx do
      task = create_task(ctx)
      task = run_current(ctx, task, %{"structured_output" => %{"status" => "bloqueado"}})
      {:ok, task} = Tasks.retry_stage(task, "De novo", by: ctx.user)
      task = run_current(ctx, task, %{"artifact" => "# Segunda"})

      assert [%StageRun{key: "a", attempt: 1} = first, %StageRun{key: "a", attempt: 2} = second] =
               Tasks.stage_attempts(task, 0)

      assert first.status == :blocked
      assert second.status == :passed
      assert second.artifact == "# Segunda"
      assert second.instructions =~ "De novo"
      assert %Job{} = second.job
      assert second.job.result =~ "resposta completa de"
      assert second.job.prompt =~ "Faça A"
    end

    test "only the stage asked for; a stage that never ran has none", ctx do
      task = create_task(ctx)

      assert [%StageRun{key: "a"}] = Tasks.stage_attempts(task, 0)
      assert Tasks.stage_attempts(task, 1) == []
      assert Tasks.stage_attempts(task, 7) == []
    end
  end

  describe "changed_files/1" do
    test "the files the task changed, as of its latest report; none before one", ctx do
      task = create_task(ctx)
      assert Tasks.changed_files(task) == []

      files = [%{"path" => "lib/login.ex", "added" => 3, "removed" => 1}]

      task =
        run_current(ctx, task, %{
          "changes" => %{"files" => files, "task_files" => files}
        })

      assert Tasks.changed_files(task) == files

      # A later report without the files does not hide them.
      task = run_current(ctx, task, %{})
      assert Tasks.changed_files(task) == files
    end
  end
end
