defmodule ClaudeControlPlane.TasksTest do
  use ClaudeControlPlane.DataCase, async: true

  import ClaudeControlPlane.Fixtures

  alias ClaudeControlPlane.{Jobs, Pipelines, Tasks}
  alias ClaudeControlPlane.Tasks.{StageRun, Task}

  setup do
    workspace = workspace_fixture()
    user = member_fixture(workspace)
    {runner, _token} = runner_fixture(workspace, user)

    runner =
      with_directories(runner, [
        %{"name" => "app", "git" => true},
        %{"name" => "notas", "git" => false}
      ])

    %{workspace: workspace, user: user, runner: runner, pipeline: pipeline_fixture(workspace)}
  end

  defp create_task(ctx, attrs \\ %{}) do
    {:ok, task} =
      Tasks.create_task(
        ctx.user,
        ctx.workspace,
        Enum.into(attrs, %{
          "title" => "Corrigir o login",
          "prompt" => "O botão de login não responde",
          "pipeline_id" => ctx.pipeline.id,
          "runner_id" => ctx.runner.id,
          "directory" => "app"
        })
      )

    task
  end

  defp current_job(task) do
    task =
      Tasks.get_task!(%ClaudeControlPlane.Workspaces.Workspace{id: task.workspace_id}, task.id)

    (Enum.find(task.stage_runs, &(&1.status == :running)) || List.last(task.stage_runs)).job
  end

  # Plays the runner: starts the task's current job and reports its end.
  defp run_current(ctx, task, report) do
    job = current_job(task)
    {:ok, _} = Jobs.mark_started(ctx.runner, job.id)

    payload =
      Map.merge(
        %{
          "status" => "succeeded",
          "exit_code" => 0,
          "structured_output" => %{"status" => "ok", "resumo" => "feito"},
          "artifact" => "# Artefato",
          "workdir" => "/w/worktrees/#{task.id}"
        },
        report
      )

    {:ok, _job} = Jobs.finish_job(ctx.runner, job.id, payload)
    Tasks.get_task!(ctx.workspace, task.id)
  end

  describe "create_task/3" do
    test "snapshots the pipeline, names a branch and hands the first stage to the runner", ctx do
      :ok = Jobs.subscribe({:runner, ctx.runner.id})
      task = create_task(ctx)

      assert %Task{status: :running, current_stage: 0, git: true} = task
      assert task.pipeline_name == ctx.pipeline.name
      assert task.pipeline_version == 1
      assert Enum.map(task.stages, & &1.key) == ["a", "b"]
      assert task.branch =~ ~r"^cp/corrigir-o-login-[0-9a-f]{8}$"

      assert_receive {:job_assign, job}
      assert job.prompt =~ "Faça A: O botão de login não responde"
      assert job.context["directory"] == "app"
      assert job.context["worktree"] == %{"task_id" => task.id, "branch" => task.branch}
      assert job.context["artifact_path"] == ".control-plane/#{task.id}/01-a.md"
      assert job.context["output_schema"]["required"] == ["status", "resumo"]
      assert job.context["timeout_ms"] == 60 * 60_000

      assert [%Task{}] = Tasks.list_tasks(ctx.workspace)
    end

    test "a directory with a project sets up the worktree and fills {{projeto.*}}", ctx do
      {:ok, project} =
        ClaudeControlPlane.Projects.create_project(ctx.workspace, %{
          "name" => "App",
          "directory" => "app",
          "setup_command" => "mix deps.get",
          "test_command" => "mix test",
          "copy_paths_text" => "deps"
        })

      pipeline =
        pipeline_fixture(ctx.workspace, %{
          "stages" => [
            %{
              "key" => "a",
              "name" => "A",
              "prompt" => "Rode {{projeto.teste}} em {{projeto.nome}}."
            }
          ]
        })

      :ok = Jobs.subscribe({:runner, ctx.runner.id})
      task = create_task(ctx, %{"pipeline_id" => pipeline.id})

      assert task.project_id == project.id
      assert task.project["test_command"] == "mix test"
      assert_receive {:job_assign, job}
      assert job.prompt =~ "Rode mix test em App."
      assert job.context["setup"] == %{"command" => "mix deps.get", "copy" => ["deps"]}

      # Editing the project does not change the task.
      {:ok, _} = ClaudeControlPlane.Projects.update_project(project, %{"test_command" => "make"})
      assert Tasks.get_task!(ctx.workspace, task.id).project["test_command"] == "mix test"
    end

    test "without a project, {{projeto.*}} is empty and there is no setup", ctx do
      pipeline =
        pipeline_fixture(ctx.workspace, %{
          "stages" => [%{"key" => "a", "name" => "A", "prompt" => "Teste: [{{projeto.teste}}]"}]
        })

      :ok = Jobs.subscribe({:runner, ctx.runner.id})
      task = create_task(ctx, %{"pipeline_id" => pipeline.id})

      assert task.project_id == nil
      assert_receive {:job_assign, job}
      assert job.prompt =~ "Teste: []"
      refute Map.has_key?(job.context, "setup")
    end

    test "a directory without git gets no worktree", ctx do
      :ok = Jobs.subscribe({:runner, ctx.runner.id})
      task = create_task(ctx, %{"directory" => "notas"})

      assert %Task{git: false, branch: nil} = task
      assert_receive {:job_assign, job}
      refute Map.has_key?(job.context, "worktree")
    end

    test "validates the pipeline, runner and directory", ctx do
      assert {:error, changeset} = Tasks.create_task(ctx.user, ctx.workspace, %{})

      assert %{title: [_], prompt: [_], pipeline_id: [_], runner_id: [_], directory: [_]} =
               errors_on(changeset)

      other = workspace_fixture()
      foreign_pipeline = pipeline_fixture(other)

      base = %{
        "title" => "t",
        "prompt" => "p",
        "pipeline_id" => ctx.pipeline.id,
        "runner_id" => ctx.runner.id,
        "directory" => "app"
      }

      for {attrs, field} <- [
            {%{"pipeline_id" => foreign_pipeline.id}, :pipeline_id},
            {%{"pipeline_id" => "nope"}, :pipeline_id},
            {%{"runner_id" => Ecto.UUID.generate()}, :runner_id},
            {%{"directory" => "inexistente"}, :directory}
          ] do
        assert {:error, changeset} =
                 Tasks.create_task(ctx.user, ctx.workspace, Map.merge(base, attrs))

        assert Map.has_key?(errors_on(changeset), field), "expected an error on #{field}"
      end
    end

    test "editing the pipeline does not change a task already running", ctx do
      task = create_task(ctx)

      {:ok, _} =
        Pipelines.update_pipeline(ctx.pipeline, %{
          "stages" => [%{"key" => "z", "name" => "Z", "prompt" => "z"}]
        })

      assert Enum.map(Tasks.get_task!(ctx.workspace, task.id).stages, & &1.key) == ["a", "b"]
    end
  end

  describe "the gate" do
    test "every stage passes and the task succeeds", ctx do
      :ok = Tasks.subscribe({:task, create_task(ctx).id})
      task = Tasks.list_tasks(ctx.workspace) |> hd()

      task = run_current(ctx, task, %{})
      assert %Task{status: :running, current_stage: 1, worktree: "/w/worktrees/" <> _} = task
      assert_receive {:task_updated, %Task{current_stage: 1}}

      second = current_job(task)
      assert second.prompt =~ "- Etapa A: .control-plane/#{task.id}/01-a.md"

      task = run_current(ctx, task, %{})
      assert %Task{status: :succeeded, finished_at: %DateTime{}} = task

      assert [
               %StageRun{key: "a", status: :passed, summary: "feito", artifact: "# Artefato"},
               %StageRun{key: "b", status: :passed}
             ] = task.stage_runs
    end

    test "an error is retried, then waits for a decision", ctx do
      task = create_task(ctx)

      task = run_current(ctx, task, %{"status" => "failed", "exit_code" => 1, "error" => "boom"})
      assert %Task{status: :running, current_stage: 0} = task
      assert [%StageRun{status: :failed, error: "boom"}, %StageRun{attempt: 2}] = task.stage_runs

      task = run_current(ctx, task, %{"artifact" => nil})
      assert %Task{status: :awaiting_decision} = task
      assert task.decision_reason =~ "falhou em 2 tentativa(s)"
      assert task.decision_reason =~ "sem escrever o artefato"
    end

    test "a missing structured output is an error", ctx do
      task = create_task(ctx)
      task = run_current(ctx, task, %{"structured_output" => nil})

      assert [
               %StageRun{status: :failed, error: "A etapa terminou sem a saída estruturada" <> _}
               | _
             ] =
               task.stage_runs
    end

    test "a blocked stage waits for a decision without retrying", ctx do
      task = create_task(ctx)

      task =
        run_current(ctx, task, %{
          "structured_output" => %{"status" => "bloqueado", "resumo" => "Falta o passo a passo"}
        })

      assert %Task{status: :awaiting_decision} = task
      assert task.decision_reason =~ "Falta o passo a passo"
      assert [%StageRun{status: :blocked}] = task.stage_runs
    end

    test "a stage that asks for approval pauses after passing", ctx do
      {:ok, pipeline} =
        Pipelines.update_pipeline(ctx.pipeline, %{
          "stages" => [
            %{"key" => "a", "name" => "Etapa A", "prompt" => "A", "pause_after" => true},
            %{"key" => "b", "name" => "Etapa B", "prompt" => "B"}
          ]
        })

      task = create_task(%{ctx | pipeline: pipeline})
      task = run_current(ctx, task, %{})

      assert %Task{status: :awaiting_decision, current_stage: 0} = task
      assert task.decision_reason =~ "pede aprovação"
    end

    test "a canceled job cancels the task", ctx do
      task = create_task(ctx)
      task = run_current(ctx, task, %{"status" => "canceled"})
      assert %Task{status: :canceled} = task
    end

    test "a job lost by a restarted runner counts as a failed attempt", ctx do
      task = create_task(ctx)
      {:ok, _} = Jobs.mark_started(ctx.runner, current_job(task).id)

      Jobs.reconcile(ctx.runner, [])

      task = Tasks.get_task!(ctx.workspace, task.id)

      assert [%StageRun{status: :failed, error: "O runner reiniciou" <> _}, %StageRun{attempt: 2}] =
               task.stage_runs
    end
  end

  describe "gates, rules and feedback" do
    setup ctx do
      {:ok, _project} =
        ClaudeControlPlane.Projects.create_project(ctx.workspace, %{
          "name" => "App",
          "directory" => "app",
          "test_command" => "mix test"
        })

      pipeline =
        pipeline_fixture(ctx.workspace, %{
          "stages" => [
            %{
              "key" => "a",
              "name" => "Corrigir",
              "prompt" => "Corrija.",
              "max_attempts" => 2,
              "gates_text" => "{{projeto.teste}}",
              "rules_text" => "risco == alto"
            },
            %{"key" => "b", "name" => "Revisar", "prompt" => "Revise."}
          ]
        })

      %{pipeline: pipeline}
    end

    test "the runner gets the stage's gate commands, rendered", ctx do
      :ok = Jobs.subscribe({:runner, ctx.runner.id})
      create_task(ctx)
      assert_receive {:job_assign, job}
      assert job.context["gates"] == [%{"command" => "mix test", "expect" => "pass"}]
    end

    test "a stage's permission profile reaches the runner with the project's commands", ctx do
      pipeline =
        pipeline_fixture(ctx.workspace, %{
          "stages" => [
            %{
              "key" => "ler",
              "name" => "Ler",
              "prompt" => "p",
              "permission_profile" => "leitura",
              "allowed_tools_text" => "Bash(git log:*)",
              "denied_tools_text" => "WebFetch"
            },
            %{"key" => "tudo", "name" => "Tudo", "prompt" => "p"}
          ]
        })

      :ok = Jobs.subscribe({:runner, ctx.runner.id})
      task = create_task(ctx, %{"pipeline_id" => pipeline.id})
      assert_receive {:job_assign, job}

      assert job.context["permissions"] == %{
               "profile" => "leitura",
               "allow" => ["Bash(git log:*)", "Bash(mix test:*)"],
               "deny" => ["WebFetch"]
             }

      run_current(ctx, task, %{})
      assert_receive {:job_assign, second}
      refute Map.has_key?(second.context, "permissions")
    end

    test "a gate that renders to nothing (no project setting) is dropped", ctx do
      :ok = Jobs.subscribe({:runner, ctx.runner.id})
      create_task(ctx, %{"directory" => "notas"})
      assert_receive {:job_assign, job}
      refute Map.has_key?(job.context, "gates")
    end

    test "a gate not met fails the attempt; the next one gets feedback", ctx do
      task = create_task(ctx)

      task =
        run_current(ctx, task, %{
          "structured_output" => %{"status" => "ok", "resumo" => "Mudei o login."},
          "gates" => [
            %{
              "command" => "mix test",
              "expect" => "pass",
              "exit_code" => 2,
              "output" => "1 test, 1 failure: LoginTest",
              "passed" => false
            }
          ]
        })

      assert [%StageRun{status: :failed, error: error}, %StageRun{attempt: 2, feedback: feedback}] =
               task.stage_runs

      assert error =~ "mix test"
      assert error =~ "esperava passar"
      assert feedback =~ error
      assert feedback =~ "Mudei o login."
      assert feedback =~ "1 failure: LoginTest"

      second = current_job(task)
      assert second.prompt =~ "A tentativa anterior desta etapa não passou"
      assert second.prompt =~ "1 failure: LoginTest"
    end

    test "gates met let the stage pass", ctx do
      task = create_task(ctx)
      gate = %{"command" => "mix test", "expect" => "pass", "exit_code" => 0, "passed" => true}
      task = run_current(ctx, task, %{"gates" => [gate]})
      assert %Task{status: :running, current_stage: 1} = task
    end

    test "a rule that matches the output pauses the task after the stage", ctx do
      task = create_task(ctx)

      output = %{"status" => "ok", "resumo" => "Feito.", "risco" => "alto"}
      task = run_current(ctx, task, %{"structured_output" => output})

      assert %Task{status: :awaiting_decision, decision_reason: reason} = task
      assert reason =~ "risco == alto"
      assert [%StageRun{status: :passed}] = task.stage_runs

      assert {:ok, %Task{status: :running, current_stage: 1}} = Tasks.advance(task, nil)
    end
  end

  describe "decisions" do
    setup ctx do
      task = create_task(ctx)

      task =
        run_current(ctx, task, %{
          "structured_output" => %{"status" => "bloqueado", "resumo" => "dúvida"}
        })

      %{task: task}
    end

    test "retry runs the stage again with the instructions", ctx do
      assert {:ok, %Task{status: :running, current_stage: 0} = task} =
               Tasks.retry_stage(ctx.task, "Use o arquivo x")

      assert [%StageRun{status: :blocked}, %StageRun{attempt: 2, instructions: "Use o arquivo x"}] =
               task.stage_runs

      assert current_job(task).prompt =~ "Use o arquivo x"
      assert Tasks.retry_stage(task, nil) == {:error, :not_awaiting}
    end

    test "advance moves on, and past the last stage the task succeeds", ctx do
      assert {:ok, %Task{status: :running, current_stage: 1} = task} =
               Tasks.advance(ctx.task, "  ")

      assert List.last(task.stage_runs).instructions == nil

      task =
        run_current(ctx, task, %{
          "structured_output" => %{"status" => "bloqueado", "resumo" => "de novo"}
        })

      assert {:ok, %Task{status: :succeeded}} = Tasks.advance(task, nil)
    end

    test "cancel ends a task waiting for a decision", ctx do
      assert {:ok, %Task{status: :canceled}} = Tasks.cancel_task(ctx.task)
      assert Tasks.cancel_task(ctx.task) == {:error, :finished}
    end
  end

  describe "talking to a running task" do
    test "an instruction waits for the next stage, then goes with it", ctx do
      task = create_task(ctx)

      assert {:ok, %Task{pending_instructions: "use o Safari"}} =
               Tasks.instruct(task, " use o Safari ")

      assert {:ok, %Task{pending_instructions: "use o Safari\n\ne o Chrome"}} =
               Tasks.instruct(task, "e o Chrome")

      assert Tasks.instruct(task, "  ") == {:error, :blank}

      task = run_current(ctx, task, %{})
      assert %Task{current_stage: 1, pending_instructions: nil} = task
      assert List.last(task.stage_runs).instructions == "use o Safari\n\ne o Chrome"
      assert current_job(task).prompt =~ "e o Chrome"
    end

    test "pause after this stage, even one that does not ask for it", ctx do
      task = create_task(ctx)
      assert {:ok, %Task{pause_requested: true}} = Tasks.request_pause(task)

      task = run_current(ctx, task, %{})

      assert %Task{status: :awaiting_decision, pause_requested: false, decision_reason: reason} =
               task

      assert reason =~ "pediu uma pausa"
    end

    test "redo from an earlier stage: it and the ones after run again", ctx do
      task = create_task(ctx)
      task = run_current(ctx, task, %{})
      task = run_current(ctx, task, %{})
      assert task.status == :succeeded

      assert {:ok, %Task{status: :running, current_stage: 0} = task} =
               Tasks.redo_from(task, 0, "refaça com testes")

      assert Enum.map(task.stage_runs, &{&1.index, &1.attempt}) == [{0, 1}, {0, 2}, {1, 1}]
      assert Enum.at(task.stage_runs, 1).instructions == "refaça com testes"

      task = run_current(ctx, task, %{})
      assert %Task{current_stage: 1} = task

      assert Enum.map(task.stage_runs, &{&1.index, &1.attempt}) == [
               {0, 1},
               {0, 2},
               {1, 1},
               {1, 2}
             ]
    end

    test "only a task that is not running can be redone, and not without its worktree", ctx do
      task = create_task(ctx)
      assert Tasks.redo_from(task, 0, nil) == {:error, :running}

      {:ok, task} = Tasks.cancel_task(task)

      task =
        task
        |> Ecto.Changeset.change(worktree_removed_at: DateTime.utc_now(:second))
        |> ClaudeControlPlane.Repo.update!()

      assert Tasks.redo_from(task, 0, nil) == {:error, :no_worktree}
    end
  end

  test "canceling a running task cancels its job", ctx do
    task = create_task(ctx)

    assert {:ok, %Task{status: :canceled}} = Tasks.cancel_task(task)
    assert current_job(task).status == :canceled
  end

  describe "the board" do
    test "filters by pipeline, runner, directory and person", ctx do
      other_pipeline = pipeline_fixture(ctx.workspace, %{"name" => "Outro"})
      colleague = member_fixture(ctx.workspace)
      a = create_task(ctx)
      b = create_task(ctx, %{"directory" => "notas", "pipeline_id" => other_pipeline.id})

      {:ok, c} =
        Tasks.create_task(colleague, ctx.workspace, %{
          "title" => "De outra pessoa",
          "prompt" => "x",
          "pipeline_id" => ctx.pipeline.id,
          "runner_id" => ctx.runner.id,
          "directory" => "app"
        })

      ids = fn filters ->
        ctx.workspace |> Tasks.list_tasks(filters) |> Enum.map(& &1.id) |> Enum.sort()
      end

      assert ids.(%{}) == Enum.sort([a.id, b.id, c.id])
      assert ids.(%{"pipeline" => "Outro"}) == [b.id]
      assert ids.(%{"directory" => "notas"}) == [b.id]
      assert ids.(%{"user_id" => colleague.id}) == [c.id]

      assert ids.(%{"runner_id" => ctx.runner.id, "directory" => "app"}) ==
               Enum.sort([a.id, c.id])

      assert ids.(%{"pipeline" => "", "runner_id" => ""}) == Enum.sort([a.id, b.id, c.id])
    end

    test "searches titles and prompts", ctx do
      a = create_task(ctx, %{"title" => "Corrigir login", "prompt" => "O botão não responde"})
      b = create_task(ctx, %{"title" => "Rodapé", "prompt" => "Ajustar o LOGIN social"})
      _c = create_task(ctx, %{"title" => "Outra", "prompt" => "nada a ver"})

      ids = fn q ->
        ctx.workspace |> Tasks.list_tasks(%{"q" => q}) |> Enum.map(& &1.id) |> Enum.sort()
      end

      assert ids.("login") == Enum.sort([a.id, b.id])
      assert ids.("botão") == [a.id]
      assert ids.("100%_") == []
    end

    test "runs a task again: same request, pipeline, runner and directory", ctx do
      task = create_task(ctx)
      {:ok, _} = Tasks.cancel_task(task)
      colleague = member_fixture(ctx.workspace)

      assert {:ok, again} = Tasks.rerun(colleague, Tasks.get_task!(ctx.workspace, task.id))
      assert again.id != task.id

      assert {again.title, again.prompt, again.directory} ==
               {task.title, task.prompt, task.directory}

      assert again.pipeline_id == task.pipeline_id
      assert again.runner_id == task.runner_id
      assert again.created_by_user_id == colleague.id
      assert again.status == :running

      assert Tasks.duplicate_params(task) == %{
               "title" => task.title,
               "prompt" => task.prompt,
               "pipeline_id" => task.pipeline_id,
               "runner_id" => task.runner_id,
               "directory" => task.directory
             }
    end

    test "counts the decisions waiting and tells who listens", ctx do
      assert Tasks.count_awaiting(ctx.workspace) == 0
      :ok = Tasks.subscribe({:decisions, ctx.workspace.id})

      task = create_task(ctx)
      blocked = %{"structured_output" => %{"status" => "bloqueado", "resumo" => "dúvida"}}
      task = run_current(ctx, task, blocked)

      assert_receive {:pending_decisions, 1}
      assert Tasks.count_awaiting(ctx.workspace) == 1
      assert [%Task{id: id, runner: %{}}] = Tasks.list_awaiting(ctx.workspace)
      assert id == task.id

      {:ok, _task} = Tasks.cancel_task(task)
      assert_receive {:pending_decisions, 0}
    end

    test "tells the workspace when a task pauses or ends", ctx do
      :ok = Tasks.subscribe({:events, ctx.workspace.id})
      task = create_task(ctx)
      task_id = task.id

      blocked = %{"structured_output" => %{"status" => "bloqueado", "resumo" => "dúvida"}}
      task = run_current(ctx, task, blocked)
      assert_receive {:task_event, %{id: ^task_id, kind: :awaiting, title: "Corrigir o login"}}

      {:ok, _} = Tasks.advance(task, nil)
      task = run_current(ctx, Tasks.get_task!(ctx.workspace, task_id), %{})
      assert task.status == :succeeded
      assert_receive {:task_event, %{id: ^task_id, kind: :succeeded}}
    end

    test "sums up a period: tasks by state and what the stages cost", ctx do
      task = create_task(ctx)
      run_current(ctx, task, %{"cost_usd" => 0.25})
      run_current(ctx, task, %{"cost_usd" => 0.5})
      create_task(ctx)

      since = DateTime.add(DateTime.utc_now(), -7, :day)
      stats = Tasks.stats(ctx.workspace, since)

      assert stats.running == 1
      assert stats.succeeded == 1
      assert stats.awaiting == 0
      assert stats.failed == 0
      assert Decimal.equal?(stats.cost_usd, Decimal.new("0.75"))

      assert Tasks.stats(workspace_fixture(), since).succeeded == 0
    end
  end

  describe "removing the worktree" do
    setup ctx do
      task = create_task(ctx)
      task = run_current(ctx, task, %{"workdir" => "/w/worktrees/x"})
      %{task: task}
    end

    test "only once the task ended, telling the runner", ctx do
      assert Tasks.remove_worktree(ctx.task) == {:error, :active}

      {:ok, task} = Tasks.cancel_task(ctx.task)
      task = Tasks.get_task!(ctx.workspace, task.id)
      :ok = Jobs.subscribe({:runner, ctx.runner.id})

      assert {:ok, %Task{worktree_removal_requested_at: %DateTime{}} = task} =
               Tasks.remove_worktree(task)

      assert_receive {:worktree_remove, %{"task_id" => task_id, "directory" => "app"}}
      assert task_id == task.id
      assert [%Task{id: ^task_id}] = Tasks.pending_worktree_removals(ctx.runner)

      assert {:ok, %Task{worktree_removed_at: %DateTime{}}} =
               Tasks.worktree_removed(ctx.runner, task.id, nil)

      assert Tasks.pending_worktree_removals(ctx.runner) == []
      task = Tasks.get_task!(ctx.workspace, task.id)
      assert Tasks.remove_worktree(task) == {:error, :no_worktree}
    end

    test "a failed removal keeps the error and can be asked again", ctx do
      {:ok, task} = Tasks.cancel_task(ctx.task)
      {:ok, task} = Tasks.remove_worktree(task)

      assert {:ok, %Task{worktree_error: "ocupado", worktree_removal_requested_at: nil} = task} =
               Tasks.worktree_removed(ctx.runner, task.id, "ocupado")

      assert Tasks.pending_worktree_removals(ctx.runner) == []
      assert {:ok, %Task{worktree_error: nil}} = Tasks.remove_worktree(task)
    end

    test "a task with no worktree has nothing to remove", ctx do
      task = create_task(ctx, %{"directory" => "notas"})
      {:ok, task} = Tasks.cancel_task(task)
      assert Tasks.remove_worktree(task) == {:error, :no_worktree}
    end

    test "only the task's runner reports the removal", ctx do
      {:ok, task} = Tasks.cancel_task(ctx.task)
      {:ok, _task} = Tasks.remove_worktree(task)
      {other, _token} = runner_fixture(ctx.workspace, ctx.user)
      assert Tasks.worktree_removed(other, task.id, nil) == {:error, :not_found}
      assert Tasks.worktree_removed(ctx.runner, "nada", nil) == {:error, :not_found}
    end
  end

  test "a workspace does not see another's tasks", ctx do
    task = create_task(ctx)
    other = workspace_fixture()

    assert Tasks.list_tasks(other) == []
    assert_raise Ecto.NoResultsError, fn -> Tasks.get_task!(other, task.id) end
  end
end
