defmodule PipeMaestro.Integrations.FeedbackTest do
  use PipeMaestro.DataCase, async: true

  import PipeMaestro.Fixtures

  alias PipeMaestro.{FakeForgejo, Integrations, Repo, Runners, Tasks}
  alias PipeMaestro.Integrations.{Feedback, Reconciler}
  alias PipeMaestro.Tasks.Task

  setup do
    workspace = workspace_fixture()
    user = member_fixture(workspace)
    fake = FakeForgejo.start()
    FakeForgejo.put_issue(fake, "acme/app", %{"number" => 3, "labels" => ["pipemaestro"]})
    {runner, _token} = runner_fixture(workspace, user, %{name: "mac"})

    {:ok, runner} =
      Runners.record_hello(
        runner,
        hello_fixture(%{directories: [%{"name" => "app", "git" => true}]})
      )

    connection = connection_fixture(workspace)
    project = project_fixture(workspace)

    {:ok, repo} =
      Integrations.link_repo(
        connection,
        user,
        %{"full_name" => "acme/app", "project_id" => project.id},
        "https://pm.test/hook"
      )

    pipeline =
      pipeline_fixture(workspace, %{
        "name" => "Correção",
        "delivery" => "pr",
        "stages" => [
          %{"key" => "a", "name" => "Etapa A", "prompt" => "A"},
          %{"key" => "b", "name" => "Etapa B", "prompt" => "B"},
          %{"key" => "c", "name" => "Etapa C", "prompt" => "C"}
        ]
      })

    {:ok, task} =
      Tasks.create_task(
        user,
        workspace,
        %{
          "title" => "Corrige login",
          "prompt" => "O login quebra.",
          "pipeline_id" => pipeline.id,
          "runner_id" => runner.id,
          "directory" => "app",
          "issue_url" => "https://forge.test/acme/app/issues/3"
        },
        issue: %{linked_repo_id: repo.id, issue_number: 3}
      )

    %{workspace: workspace, fake: fake, connection: connection, repo: repo, task: task}
  end

  defp put_task(task, changes), do: task |> Ecto.Changeset.change(changes) |> Repo.update!()
  defp fake_repo(ctx), do: FakeForgejo.repo(ctx.fake, "acme/app")
  defp labels(ctx), do: Enum.map(fake_repo(ctx).issues[3]["labels"], & &1["name"])

  defp calls(ctx, method, path),
    do: Enum.count(FakeForgejo.calls(ctx.fake), &(&1 == {method, path}))

  describe "desired/4" do
    test "labels, comment and statuses follow the task", ctx do
      task = %{ctx.task | current_stage: 1, status: :running, head_sha: "abc", branch: "cp/x"}

      desired =
        Feedback.desired(task, ctx.repo, %{0 => :passed, 1 => :running}, "https://pm.test/t")

      assert desired.label == "pipemaestro:em-andamento"
      assert desired.comment =~ "<!-- pipemaestro:status -->"
      assert desired.comment =~ "✅ Etapa A"
      assert desired.comment =~ "⏳ Etapa B"
      assert desired.comment =~ "▫️ Etapa C"

      assert Enum.map(desired.statuses, &{&1.context, &1.state}) == [
               {"pipemaestro/a", "success"},
               {"pipemaestro/b", "pending"}
             ]

      assert %{head: "cp/x", base: "main", title: "Corrige login", ready: false} = desired.pr
      assert desired.pr.block =~ "Closes https://forge.test/acme/app/issues/3"
      assert desired.notify == nil
    end

    test "a decision is shown with its questions and calls for a notification", ctx do
      task = %{
        ctx.task
        | current_stage: 1,
          status: :awaiting_decision,
          decision_reason: "faltou contexto",
          decision_questionnaire: %{
            "perguntas" => [
              %{
                "pergunta" => "Qual banco?",
                "opcoes" => [%{"rotulo" => "Postgres"}, %{"rotulo" => "MySQL"}]
              }
            ]
          }
      }

      desired = Feedback.desired(task, ctx.repo, %{1 => :blocked}, "https://pm.test/t")

      assert desired.label == "pipemaestro:aguardando-decisao"
      assert desired.comment =~ "faltou contexto"
      assert desired.comment =~ "1. Qual banco? (Postgres · MySQL)"
      assert desired.statuses == []
      assert {"decision:1:" <> _, text} = desired.notify
      assert text =~ "espera uma decisão"
    end

    test "an exhausted stage fails; a finished task is ready", ctx do
      exhausted =
        Feedback.desired(
          %{ctx.task | status: :awaiting_decision, head_sha: "abc"},
          ctx.repo,
          %{0 => :failed},
          "u"
        )

      assert [%{state: "failure"}] = exhausted.statuses

      done =
        Feedback.desired(
          %{
            ctx.task
            | status: :succeeded,
              head_sha: "abc",
              branch: "cp/x",
              pr_url: "https://forge.test/p/1"
          },
          ctx.repo,
          %{},
          "u"
        )

      assert done.label == "pipemaestro:pronto"
      assert Enum.all?(done.statuses, &(&1.state == "success"))
      assert done.pr.ready
      assert {"ready", _} = done.notify
    end
  end

  describe "sync/1" do
    test "creates the status comment once, then edits it only when something changes", ctx do
      assert Feedback.sync(ctx.task.id) == :ok
      assert [%{"id" => id, "body" => body}] = fake_repo(ctx).comments
      assert body =~ "Etapa A"
      assert Repo.reload!(ctx.task).issue_feedback["comment_id"] == id

      assert Feedback.sync(ctx.task.id) == :unchanged
      assert calls(ctx, "PATCH", "/api/v1/repos/acme/app/issues/comments/#{id}") == 0

      put_task(Repo.reload!(ctx.task), current_stage: 1)
      assert Feedback.sync(ctx.task.id) == :ok
      assert [%{"id" => ^id, "body" => edited}] = fake_repo(ctx).comments
      assert edited =~ "✅ Etapa A"
    end

    test "swaps the state label and keeps the trigger's", ctx do
      Feedback.sync(ctx.task.id)
      assert "pipemaestro:em-andamento" in labels(ctx)

      put_task(Repo.reload!(ctx.task), status: :awaiting_decision, decision_reason: "dúvida")
      Feedback.sync(ctx.task.id)
      assert "pipemaestro:aguardando-decisao" in labels(ctx)
      refute "pipemaestro:em-andamento" in labels(ctx)
      assert "pipemaestro" in labels(ctx)
    end

    test "notifies a decision once, even synced again", ctx do
      put_task(ctx.task, status: :awaiting_decision, decision_reason: "dúvida")
      Feedback.sync(ctx.task.id)
      put_task(Repo.reload!(ctx.task), decision_reason: "dúvida, de novo")
      Feedback.sync(ctx.task.id)

      assert Enum.count(fake_repo(ctx).comments, &(&1["body"] =~ "espera uma decisão")) == 1
    end

    test "posts a status per stage on the pushed commit", ctx do
      put_task(ctx.task, head_sha: "abc123", current_stage: 1)
      Repo.update_all(Tasks.StageRun, set: [status: :passed])
      Feedback.sync(ctx.task.id)

      assert [{"pipemaestro/a", "success"}, {"pipemaestro/b", "pending"}] =
               Enum.map(fake_repo(ctx).statuses, &{&1["context"], &1["state"]})

      put_task(Repo.reload!(ctx.task), current_stage: 2)
      Feedback.sync(ctx.task.id)
      # Etapa A was already success on that commit: only B and C are written.
      assert length(fake_repo(ctx).statuses) == 4
    end

    test "opens the draft pull request, adopts it after and marks it ready", ctx do
      task = put_task(ctx.task, head_sha: "abc123")
      Feedback.sync(task.id)

      assert [%{"title" => "WIP: Corrige login", "head" => %{"ref" => branch}, "body" => body}] =
               fake_repo(ctx).pulls

      assert branch == task.branch
      assert body =~ "<!-- pipemaestro:inicio -->"
      assert Repo.reload!(task).pr_url == "https://forge.test/acme/app/pulls/1"

      FakeForgejo.edit_pull(ctx.fake, "acme/app", 1, fn pull ->
        %{pull | "body" => "Nota de alguém\n\n" <> pull["body"]}
      end)

      put_task(Repo.reload!(task), status: :succeeded)
      Feedback.sync(task.id)

      assert [%{"title" => "Corrige login", "body" => body}] = fake_repo(ctx).pulls
      assert body =~ "Nota de alguém"
      assert Enum.count(fake_repo(ctx).comments, &(&1["body"] =~ "O pull request de")) == 1
      assert "pipemaestro:pronto" in labels(ctx)
    end

    test "a failure is kept and the reconciliation tries again", ctx do
      FakeForgejo.fail(ctx.fake, {"POST", "/api/v1/repos/acme/app/issues/3/comments"}, 500, 1)

      assert {:error, message} = Feedback.sync(ctx.task.id)
      assert message =~ "comentário"
      assert %{"dirty" => true, "error" => ^message} = Repo.reload!(ctx.task).issue_feedback
      assert Feedback.dirty_task_ids() == [ctx.task.id]

      assert %{feedback: 1} = Reconciler.run(DateTime.utc_now())
      assert %{"dirty" => false, "error" => nil} = Repo.reload!(ctx.task).issue_feedback
    end

    test "skips a task without a linked repository or whose connection leaves it to the runner",
         ctx do
      put_task(ctx.task, linked_repo_id: nil)
      assert Feedback.sync(ctx.task.id) == :skipped

      put_task(Repo.reload!(ctx.task), linked_repo_id: ctx.repo.id)
      ctx.connection |> Ecto.Changeset.change(api_mode: "runner") |> Repo.update!()
      assert Feedback.sync(ctx.task.id) == :skipped
      assert fake_repo(ctx).comments == []
    end
  end

  describe "the runner's delivery" do
    test "only pushes when the platform keeps the pull request", ctx do
      [job] = Repo.all(PipeMaestro.Jobs.Job)
      assert job.context["delivery"] == %{"push" => true}

      ctx.connection |> Ecto.Changeset.change(api_mode: "runner") |> Repo.update!()
      assert Integrations.keeps_pull_request?(ctx.task) == false
    end

    test "keeps the pushed commit", ctx do
      [job] = Repo.all(PipeMaestro.Jobs.Job)
      runner = Repo.get!(PipeMaestro.Runners.Runner, ctx.task.runner_id)
      {:ok, _} = PipeMaestro.Jobs.mark_started(runner, job.id)

      {:ok, _} =
        PipeMaestro.Jobs.finish_job(runner, job.id, %{
          "status" => "succeeded",
          "structured_output" => %{"status" => "ok", "resumo" => "feito"},
          "artifact" => "# feito",
          "delivery" => %{
            "commit" => "abc123",
            "pushed" => true,
            "pr_url" => nil,
            "commented" => false
          }
        })

      assert %Task{head_sha: "abc123"} = Repo.reload!(ctx.task)
    end
  end
end
