defmodule PipeMaestro.NotificationsTest do
  use PipeMaestro.DataCase, async: true

  import PipeMaestro.Fixtures

  alias PipeMaestro.{
    Jobs,
    Maintenance,
    Notifications,
    Proposals,
    Repo,
    Runners,
    Tasks,
    Workspaces
  }

  alias PipeMaestro.Accounts.Scope
  alias PipeMaestro.Notifications.{Execution, Notification}
  alias PipeMaestro.Tasks.Task

  @directories [%{"name" => "app", "git" => true}]

  @analysis %{
    "diagnostico" => "O **timeout** do login é curto.",
    "perguntas" => [
      %{
        "titulo" => "Correção",
        "pergunta" => "Como corrigir a falha?",
        "multipla" => false,
        "opcoes" => [
          %{"rotulo" => "Desistir", "descricao" => "Cancela", "recomendada" => false},
          %{"rotulo" => "Tentar de novo", "descricao" => "Outra vez", "recomendada" => true}
        ]
      }
    ]
  }

  @pipeline_output %{
    "analise" => "Um app Phoenix.",
    "verificacoes" => [%{"comando" => "mix test", "passou" => true}],
    "pipeline" => %{
      "name" => "Entrega",
      "stages" => [%{"key" => "plano", "name" => "Plano", "prompt" => "Planeje"}]
    }
  }

  setup do
    workspace = workspace_fixture()
    # The first member is the workspace's admin.
    admin = member_fixture(workspace, %{name: "Ana Admin"})
    member = member_fixture(workspace, %{name: "Beto Membro"}, :member)
    {runner, _token} = runner_fixture(workspace, admin, %{name: "mac"})

    {:ok, runner} =
      Runners.record_hello(
        runner,
        hello_fixture(%{directories: @directories, capabilities: ["scratch"]})
      )

    %{
      workspace: workspace,
      admin: admin,
      member: member,
      runner: runner,
      project: project_fixture(runner, "app"),
      pipeline: pipeline_fixture(workspace)
    }
  end

  defp scope(user, workspace) do
    user
    |> Scope.for_user()
    |> Scope.put_workspace(workspace, Workspaces.role(workspace, user))
  end

  defp create_task(ctx, user, attrs \\ %{}) do
    {:ok, task} =
      Tasks.create_task(
        user,
        ctx.workspace,
        Enum.into(attrs, %{
          "title" => "Corrigir o login",
          "prompt" => "O botão de login não responde",
          "pipeline_id" => ctx.pipeline.id,
          "project_id" => ctx.project.id
        })
      )

    task
  end

  # Plays the runner: starts the task's current job and reports its end.
  defp run_current(ctx, task, output \\ %{"status" => "ok", "resumo" => "feito"}) do
    task = Tasks.get_task!(ctx.workspace, task.id)
    job = (Enum.find(task.stage_runs, &(&1.status == :running)) || List.last(task.stage_runs)).job
    {:ok, _} = Jobs.mark_started(ctx.runner, job.id)

    {:ok, _job} =
      Jobs.finish_job(ctx.runner, job.id, %{
        "status" => "succeeded",
        "exit_code" => 0,
        "structured_output" => output,
        "artifact" => "# Artefato"
      })

    Tasks.get_task!(ctx.workspace, task.id)
  end

  defp pause(ctx, task),
    do: run_current(ctx, task, %{"status" => "bloqueado", "resumo" => "Qual navegador?"})

  # A notification written straight to the table, for listing and scope.
  defp notification!(user, workspace, attrs \\ %{}) do
    Notification
    |> struct(
      Enum.into(attrs, %{
        workspace_id: workspace.id,
        user_id: user.id,
        kind: :task_succeeded,
        title: "Algo foi concluída",
        body: nil
      })
    )
    |> Repo.insert!()
  end

  # Sorted: notifications of the same second have no order among them.
  defp kinds(scope), do: scope |> Notifications.list_for() |> Enum.map(& &1.kind) |> Enum.sort()

  describe "a task's pause and end reach its people" do
    test "a pause notifies the creator, once, with the reason", ctx do
      task = pause(ctx, create_task(ctx, ctx.member))
      member = scope(ctx.member, ctx.workspace)

      assert [%{__struct__: Notification} = n] = Notifications.list_for(member)
      assert n.kind == :task_awaiting_decision
      assert n.title == "Corrigir o login aguarda decisão"
      assert n.body =~ "Qual navegador?"
      assert n.task_id == task.id
      assert n.read_at == nil
      assert Notifications.count_unread(member) == 1

      # The admin did not create it and does not decide it.
      assert Notifications.list_for(scope(ctx.admin, ctx.workspace)) == []
    end

    test "success, failure and cancel each notify", ctx do
      task = create_task(ctx, ctx.member)
      task = run_current(ctx, task)
      %Task{status: :succeeded} = run_current(ctx, task)
      assert [:task_succeeded] = kinds(scope(ctx.member, ctx.workspace))

      assert [%{__struct__: Notification, title: "Corrigir o login foi concluída"}] =
               Notifications.list_for(scope(ctx.member, ctx.workspace))

      other = create_task(ctx, ctx.member, %{"title" => "Tela branca"})
      {:ok, _} = Tasks.cancel_task(pause(ctx, other), by: ctx.member)

      assert [:task_awaiting_decision, :task_canceled, :task_succeeded] =
               kinds(scope(ctx.member, ctx.workspace))

      assert %{__struct__: Notification, title: "Tela branca foi cancelada"} =
               ctx.member
               |> scope(ctx.workspace)
               |> Notifications.list_for()
               |> Enum.find(&(&1.kind == :task_canceled))

      failed = create_task(ctx, ctx.member, %{"title" => "Build quebrado"})
      Notifications.notify_task(%{failed | status: :failed}, :failed)

      assert %{__struct__: Notification, title: "Build quebrado falhou", task_id: failed_id} =
               ctx.member
               |> scope(ctx.workspace)
               |> Notifications.list_for()
               |> Enum.find(&(&1.kind == :task_failed))

      assert failed_id == failed.id
    end

    test "the decision's owner hears too, never twice", ctx do
      task = pause(ctx, create_task(ctx, ctx.member))
      # The creator owns the decision: a single notification.
      assert Notifications.count_unread(scope(ctx.member, ctx.workspace)) == 1

      colleague = member_fixture(ctx.workspace, %{}, :member)
      {:ok, task} = Tasks.assign_decision(task, colleague)
      {:ok, _} = Tasks.cancel_task(task, by: colleague)

      assert [:task_awaiting_decision, :task_canceled] = kinds(scope(ctx.member, ctx.workspace))
      assert [:task_canceled] = kinds(scope(colleague, ctx.workspace))
    end

    test "a task without a creator goes to the workspace's admins", ctx do
      task = create_task(ctx, ctx.member)

      task
      |> Ecto.Changeset.change(created_by_user_id: nil)
      |> Repo.update!()

      other_admin = member_fixture(ctx.workspace, %{}, :admin)
      pause(ctx, task)

      assert [:task_awaiting_decision] = kinds(scope(ctx.admin, ctx.workspace))
      assert [:task_awaiting_decision] = kinds(scope(other_admin, ctx.workspace))
      assert kinds(scope(ctx.member, ctx.workspace)) == []
    end

    test "a creator who left the workspace is not notified; its admins are", ctx do
      task = create_task(ctx, ctx.member)
      :ok = Workspaces.remove_member(ctx.workspace, ctx.member)
      pause(ctx, task)

      refute Repo.exists?(from n in Notification, where: n.user_id == ^ctx.member.id)
      assert [:task_awaiting_decision] = kinds(scope(ctx.admin, ctx.workspace))
    end

    test "the notification is told live to its recipient", ctx do
      member = scope(ctx.member, ctx.workspace)
      :ok = Notifications.subscribe(member)

      pause(ctx, create_task(ctx, ctx.member))

      assert_receive {:notification, %{__struct__: Notification, kind: :task_awaiting_decision}}
      assert_receive {:unread_count, 1}
    end
  end

  describe "a proposal ready for review" do
    defp ask(ctx, kind, attrs) do
      {:ok, job} =
        Proposals.request(
          kind,
          ctx.member,
          ctx.workspace,
          Map.merge(%{"project_id" => ctx.project.id}, attrs)
        )

      job
    end

    defp finish(ctx, job, attrs) do
      {:ok, _started} = Jobs.mark_started(ctx.runner, job.id)
      {:ok, job} = Jobs.finish_job(ctx.runner, job.id, attrs)
      job
    end

    test "notifies who asked when it succeeds", ctx do
      job = ask(ctx, "pipeline", %{"request" => "Um pipeline com PR"})
      finish(ctx, job, %{"status" => "succeeded", "structured_output" => @pipeline_output})

      assert [%{__struct__: Notification, kind: :proposal_ready, job_id: job_id, task_id: nil}] =
               Notifications.list_for(scope(ctx.member, ctx.workspace))

      assert job_id == job.id
    end

    test "a failed proposal tells who asked, with the error", ctx do
      job = ask(ctx, "pipeline", %{"request" => "Um pipeline com PR"})
      finish(ctx, job, %{"status" => "failed", "error" => "sem créditos"})

      assert [
               %{
                 __struct__: Notification,
                 kind: :proposal_failed,
                 job_id: job_id,
                 task_id: nil,
                 body: "sem créditos"
               }
             ] = Notifications.list_for(scope(ctx.member, ctx.workspace))

      assert job_id == job.id
    end

    test "a failed proposal does not reach someone who did not ask", ctx do
      job = ask(ctx, "pipeline", %{"request" => "Um pipeline com PR"})
      finish(ctx, job, %{"status" => "failed", "error" => "sem créditos"})

      someone_else = member_fixture(ctx.workspace, %{}, :member)
      assert Notifications.list_for(scope(someone_else, ctx.workspace)) == []
    end

    test "a task proposal approved on its own becomes a task, not a notification", ctx do
      pipeline_fixture(ctx.workspace, %{"name" => "Correção de bug"})
      job = ask(ctx, "task", %{"request" => "O login trava", "auto_approve" => "true"})

      finish(ctx, job, %{
        "status" => "succeeded",
        "structured_output" => %{
          "analise" => "O lock não tem timeout.",
          "titulo" => "Destravar o login",
          "descricao" => "## Problema\n\nTrava.",
          "pipeline" => "Correção de bug",
          "pronta" => true,
          "perguntas" => []
        }
      })

      refute :proposal_ready in kinds(scope(ctx.member, ctx.workspace))
    end

    test "an analysis of a failure is not a proposal to review", ctx do
      task = failed_into_analysis(ctx)
      analysis = Jobs.get_job!(ctx.workspace, task.decision_analysis_job_id)
      finish(ctx, analysis, %{"status" => "succeeded", "structured_output" => @analysis})

      refute :proposal_ready in kinds(scope(ctx.member, ctx.workspace))
    end
  end

  # A task whose single-attempt stage failed: it pauses and asks for an analysis.
  defp failed_into_analysis(ctx) do
    pipeline =
      pipeline_fixture(ctx.workspace, %{
        "stages" => [
          %{"key" => "a", "name" => "Etapa A", "prompt" => "Faça A", "max_attempts" => 1}
        ]
      })

    task = create_task(ctx, ctx.member, %{"pipeline_id" => pipeline.id, "title" => "Analisada"})
    job = hd(Tasks.get_task!(ctx.workspace, task.id).stage_runs).job
    {:ok, _} = Jobs.mark_started(ctx.runner, job.id)

    {:ok, _} =
      Jobs.finish_job(ctx.runner, job.id, %{
        "status" => "failed",
        "exit_code" => 1,
        "error" => "x"
      })

    task = Tasks.get_task!(ctx.workspace, task.id)
    assert %Task{status: :awaiting_decision, decision_analysis_job_id: id} = task
    assert id, "expected the failure to ask for an analysis"
    task
  end

  describe "the inbox, by scope" do
    test "lists the newest first, pages by cursor and filters the unread", ctx do
      now = DateTime.utc_now(:second)

      [newest, middle, oldest] =
        for {title, ago} <- [{"três", 1}, {"dois", 2}, {"um", 3}] do
          notification!(ctx.member, ctx.workspace, %{
            title: title,
            inserted_at: DateTime.add(now, -ago, :minute)
          })
        end

      member = scope(ctx.member, ctx.workspace)

      assert ["três", "dois", "um"] = member |> Notifications.list_for() |> Enum.map(& &1.title)

      assert [%{id: first}, %{id: second}] = Notifications.list_for(member, limit: 2)
      assert {first, second} == {newest.id, middle.id}

      assert [%{id: last}] =
               Notifications.list_for(member, limit: 2, before: {middle.inserted_at, middle.id})

      assert last == oldest.id

      {:ok, _} = Notifications.mark_read(member, middle.id)

      assert ["três", "um"] =
               member |> Notifications.list_for(unread: true) |> Enum.map(& &1.title)

      assert Notifications.count_unread(member) == 2
    end

    test "marking one as read tells the new count", ctx do
      n = notification!(ctx.member, ctx.workspace)
      member = scope(ctx.member, ctx.workspace)
      :ok = Notifications.subscribe(member)

      assert {:ok, %{__struct__: Notification, read_at: %DateTime{}}} =
               Notifications.mark_read(member, n.id)

      assert_receive {:unread_count, 0}
      assert Notifications.count_unread(member) == 0
    end

    test "marking all as read clears only this person's, in this workspace", ctx do
      other_workspace = workspace_fixture()
      {:ok, _} = Workspaces.add_member(other_workspace, ctx.member, :member)

      for _ <- 1..2, do: notification!(ctx.member, ctx.workspace)
      notification!(ctx.member, other_workspace)
      notification!(ctx.admin, ctx.workspace)

      member = scope(ctx.member, ctx.workspace)
      :ok = Notifications.subscribe(member)

      assert {2, _} = Notifications.mark_all_read(member)
      assert_receive {:unread_count, 0}

      assert Notifications.count_unread(member) == 0
      assert Notifications.count_unread(scope(ctx.member, other_workspace)) == 1
      assert Notifications.count_unread(scope(ctx.admin, ctx.workspace)) == 1
    end

    test "nobody reads or marks another person's or another workspace's", ctx do
      other_workspace = workspace_fixture()
      {:ok, _} = Workspaces.add_member(other_workspace, ctx.member, :member)

      admins = notification!(ctx.admin, ctx.workspace)
      elsewhere = notification!(ctx.member, other_workspace)
      member = scope(ctx.member, ctx.workspace)

      assert Notifications.list_for(member) == []
      assert Notifications.mark_read(member, admins.id) == {:error, :not_found}
      assert Notifications.mark_read(member, elsewhere.id) == {:error, :not_found}
      assert Notifications.mark_read(member, Ecto.UUID.generate()) == {:error, :not_found}

      assert Repo.get!(Notification, admins.id).read_at == nil
      assert Repo.get!(Notification, elsewhere.id).read_at == nil
    end
  end

  describe "what is running now" do
    test "tasks running, waiting and in line, with their stage, runner and creator", ctx do
      {:ok, workspace} = Workspaces.update_workspace(ctx.workspace, %{"max_running_tasks" => 1})
      ctx = %{ctx | workspace: workspace}

      done = create_task(ctx, ctx.admin, %{"title" => "Feita"})
      %Task{status: :succeeded} = ctx |> run_current(done) |> then(&run_current(ctx, &1))
      # A paused task leaves its place in the workspace's limit.
      paused = pause(ctx, create_task(ctx, ctx.admin, %{"title" => "Parada"}))
      running = create_task(ctx, ctx.member, %{"title" => "Rodando"})
      queued = create_task(ctx, ctx.member, %{"title" => "Na fila"})
      assert %Task{status: :queued} = queued

      executions = Notifications.active_executions(workspace)
      by_id = Map.new(executions, &{&1.id, &1})

      assert %{__struct__: Execution, type: :task, status: :running, title: "Rodando"} =
               by_id[running.id]

      # "Etapa 1 de 2": the stage is counted from one.
      assert %{__struct__: Execution, stage: 1, stage_count: 2, runner_name: "mac"} =
               by_id[running.id]

      assert by_id[running.id].creator_id == ctx.member.id
      assert by_id[running.id].creator_name == "Beto Membro"
      assert %DateTime{} = by_id[running.id].started_at

      assert %{__struct__: Execution, status: :awaiting_decision, creator_name: "Ana Admin"} =
               by_id[paused.id]

      assert %{__struct__: Execution, status: :queued} = by_id[queued.id]
      refute Map.has_key?(by_id, done.id)

      assert %{
               running: [%{id: running_id}],
               awaiting_decision: [%{id: paused_id}],
               queued: [%{id: queued_id}]
             } = Notifications.group(executions)

      assert {running_id, paused_id, queued_id} == {running.id, paused.id, queued.id}
    end

    test "proposals being written, but not a failure's analysis", ctx do
      job =
        ask(ctx, "pipeline", %{"request" => "Um pipeline com PR"})

      analysed = failed_into_analysis(ctx)

      executions = Notifications.active_executions(ctx.workspace)
      by_id = Map.new(executions, &{&1.id, &1})

      assert %{__struct__: Execution, type: :proposal, status: :queued, proposal_kind: "pipeline"} =
               by_id[job.id]

      assert by_id[job.id].creator_id == ctx.member.id
      refute Map.has_key?(by_id, analysed.decision_analysis_job_id)

      assert %{__struct__: Execution, type: :task, status: :awaiting_decision} =
               by_id[analysed.id]

      {:ok, _} = Jobs.mark_started(ctx.runner, job.id)

      assert %{__struct__: Execution, status: :running} =
               ctx.workspace |> Notifications.active_executions() |> Enum.find(&(&1.id == job.id))
    end

    test "only mine: what the person started", ctx do
      mine = create_task(ctx, ctx.member, %{"title" => "Minha"})
      theirs = create_task(ctx, ctx.admin, %{"title" => "Dela"})

      ids =
        ctx.workspace |> Notifications.active_executions(mine: ctx.member) |> Enum.map(& &1.id)

      assert mine.id in ids
      refute theirs.id in ids
    end

    test "every change of a task or a proposal is told to the workspace", ctx do
      :ok = Notifications.subscribe(scope(ctx.member, ctx.workspace))
      workspace_id = ctx.workspace.id

      create_task(ctx, ctx.member)
      assert_receive {:executions_changed, ^workspace_id}

      ask(ctx, "pipeline", %{"request" => "Um pipeline com PR"})
      assert_receive {:executions_changed, ^workspace_id}
    end
  end

  describe "retention" do
    test "read notifications older than 30 days go; recent and unread ones stay", ctx do
      now = DateTime.utc_now(:second)

      old_read =
        notification!(ctx.member, ctx.workspace, %{
          read_at: DateTime.add(now, -31, :day),
          inserted_at: DateTime.add(now, -40, :day)
        })

      recent_read =
        notification!(ctx.member, ctx.workspace, %{read_at: DateTime.add(now, -29, :day)})

      old_unread =
        notification!(ctx.member, ctx.workspace, %{inserted_at: DateTime.add(now, -90, :day)})

      assert %{notifications: 1} = Maintenance.run(DateTime.utc_now())

      refute Repo.get(Notification, old_read.id)
      assert Repo.get(Notification, recent_read.id)
      assert Repo.get(Notification, old_unread.id)
    end
  end
end
