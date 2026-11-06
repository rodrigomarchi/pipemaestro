defmodule PipeMaestro.Integrations.ConversationTest do
  use PipeMaestro.DataCase, async: true

  import PipeMaestro.Fixtures

  alias PipeMaestro.{Audit, FakeForgejo, Integrations, Repo, Runners, Tasks}
  alias PipeMaestro.Integrations.{Connection, Delivery, Ingest}
  alias PipeMaestro.Tasks.Task

  @fixtures Path.expand("../../support/fixtures/forgejo", __DIR__)

  setup do
    workspace = workspace_fixture()
    user = member_fixture(workspace)
    fake = FakeForgejo.start(permissions: %{"ana" => "write", "rui" => "read", "bia" => "write"})
    FakeForgejo.put_issue(fake, "acme/app", %{"number" => 3, "labels" => ["pipemaestro"]})
    {runner, _token} = runner_fixture(workspace, user, %{name: "mac"})

    {:ok, runner} =
      Runners.record_hello(
        runner,
        hello_fixture(%{directories: [%{"name" => "app", "git" => true}]})
      )

    connection = connection_fixture(workspace)

    {:ok, repo} =
      Integrations.link_repo(
        connection,
        user,
        %{"full_name" => "acme/app", "project_id" => project_fixture(workspace).id},
        "https://pm.test/hook"
      )

    {:ok, task} =
      Tasks.create_task(
        user,
        workspace,
        %{
          "title" => "Corrige login",
          "prompt" => "O login quebra.",
          "pipeline_id" => pipeline_fixture(workspace).id,
          "runner_id" => runner.id,
          "directory" => "app",
          "issue_url" => "https://forge.test/acme/app/issues/3"
        },
        issue: %{linked_repo_id: repo.id, issue_number: 3}
      )

    %{workspace: workspace, user: user, fake: fake, connection: connection, task: task}
  end

  defp payload(name, changes) do
    @fixtures
    |> Path.join(name <> ".json")
    |> File.read!()
    |> JSON.decode!()
    |> deep_merge(changes)
  end

  defp deep_merge(left, right),
    do:
      Map.merge(left, right, fn _k, l, r ->
        if is_map(l) and is_map(r), do: deep_merge(l, r), else: r
      end)

  defp deliver(ctx, type, payload) do
    body = JSON.encode!(payload)

    signature =
      :crypto.mac(:hmac, :sha256, Connection.webhook_secret(ctx.connection), body)
      |> Base.encode16(case: :lower)

    id = "d-#{System.unique_integer([:positive])}"

    headers = %{
      "x-forgejo-event-type" => type,
      "x-forgejo-delivery" => id,
      "x-forgejo-signature" => signature
    }

    {:ok, delivery} = Ingest.record_webhook(ctx.connection.id, headers, body)
    Ingest.process(delivery)
  end

  defp comment(ctx, body, extra \\ %{}) do
    comment =
      Map.merge(
        %{
          "id" => System.unique_integer([:positive]),
          "body" => body,
          "user" => %{"login" => "ana"}
        },
        extra
      )

    deliver(ctx, "issue_comment", payload("issue_comment", %{"comment" => comment}))
  end

  defp await(ctx, attrs \\ %{}) do
    ctx.task
    |> Ecto.Changeset.change(
      Map.merge(%{status: :awaiting_decision, decision_reason: "faltou contexto"}, attrs)
    )
    |> Repo.update!()
  end

  defp comments(ctx), do: FakeForgejo.repo(ctx.fake, "acme/app").comments

  describe "commands" do
    test "seguir decides like the screen, with a 👍 and the login in the audit", ctx do
      await(ctx)

      assert %Delivery{status: "processed", task_id: task_id, outcome: outcome} =
               comment(ctx, "/pipemaestro seguir use a opção B", %{"id" => 77})

      assert task_id == ctx.task.id
      assert outcome =~ "ana"
      refute Repo.reload!(ctx.task).status == :awaiting_decision
      assert {:comment, 77, "+1"} in FakeForgejo.repo(ctx.fake, "acme/app").reactions

      assert [event] =
               Enum.filter(
                 Audit.list_events(ctx.workspace),
                 &(&1.action == "task.decided_from_host")
               )

      assert event.details == %{"login" => "ana", "action" => "advance"}
    end

    test "the same comment delivered twice is applied once", ctx do
      await(ctx)
      assert %Delivery{status: "processed"} = comment(ctx, "/pipemaestro refazer", %{"id" => 80})
      await(ctx)

      assert %Delivery{status: "ignored", outcome: "comando já aplicado"} =
               comment(ctx, "/pipemaestro refazer", %{"id" => 80})
    end

    test "a command that does not apply now gets an answer with the commands", ctx do
      assert %Delivery{status: "ignored", outcome: outcome} = comment(ctx, "/pipemaestro seguir")
      assert outcome =~ "não espera uma decisão"
      assert [%{"body" => body}] = comments(ctx)
      assert body =~ "/pipemaestro corrigir"
    end

    test "responder answers the questions in order", ctx do
      questionnaire = %{
        "origem" => "agente",
        "perguntas" => [
          %{
            "titulo" => "Banco",
            "pergunta" => "Qual banco?",
            "multipla" => false,
            "opcoes" => [
              %{"rotulo" => "Postgres", "descricao" => "O atual.", "recomendada" => true},
              %{"rotulo" => "MySQL", "descricao" => "Outro.", "recomendada" => false}
            ]
          }
        ]
      }

      await(ctx, %{decision_questionnaire: questionnaire})

      assert %Delivery{status: "processed"} = comment(ctx, "/pipemaestro responder\n1. postgres")
      assert [decision] = Repo.preload(Repo.reload!(ctx.task), :decisions).decisions

      assert decision.answers == %{"respostas" => [%{"escolhas" => ["Postgres"], "outro" => nil}]}
    end

    test "pausar and cancelar act on a running task", ctx do
      assert %Delivery{status: "processed"} = comment(ctx, "/pipemaestro pausar")
      assert Repo.reload!(ctx.task).pause_requested

      assert %Delivery{status: "processed"} = comment(ctx, "/pipemaestro cancelar")
      assert Repo.reload!(ctx.task).status == :canceled
    end

    test "corrigir starts a correction of a finished task", ctx do
      ctx.task |> Ecto.Changeset.change(status: :succeeded) |> Repo.update!()

      assert %Delivery{status: "processed"} =
               comment(ctx, "/pipemaestro corrigir falta o teste do espaço")

      task = Repo.reload!(ctx.task)
      assert task.status == :running
      assert List.last(task.stages).name =~ "Correção"
    end

    test "an unknown word on an active task gets the commands; a reader is ignored", ctx do
      assert %Delivery{status: "ignored", outcome: "comando desconhecido"} =
               comment(ctx, "/pipemaestro dançar")

      assert [%{"body" => _help}] = comments(ctx)

      reader = comment(ctx, "/pipemaestro cancelar", %{"user" => %{"login" => "rui"}})

      assert %Delivery{status: "ignored", outcome: "o autor não tem permissão de escrita"} =
               reader

      refute Repo.reload!(ctx.task).status == :canceled
    end

    test "need the platform to call the host", ctx do
      ctx.connection |> Ecto.Changeset.change(api_mode: "runner") |> Repo.update!()

      assert %Delivery{
               status: "ignored",
               outcome: "comandos precisam que a plataforma chame o host"
             } = comment(ctx, "/pipemaestro cancelar")
    end

    test "on the pull request, find the task by its branch", ctx do
      await(ctx)
      pr = %{"head" => %{"ref" => ctx.task.branch}, "number" => 7}

      comment =
        payload("issue_comment_pull", %{
          "pull_request" => pr,
          "comment" => %{
            "id" => 90,
            "body" => "/pipemaestro seguir",
            "user" => %{"login" => "ana"}
          }
        })

      assert %Delivery{status: "processed", task_id: task_id} =
               deliver(ctx, "pull_request_comment", comment)

      assert task_id == ctx.task.id
    end
  end

  describe "the pull request" do
    test "a review asking for changes on a finished task becomes a correction", ctx do
      ctx.task |> Ecto.Changeset.change(status: :succeeded) |> Repo.update!()

      review =
        payload("pull_request_review_rejected", %{
          "pull_request" => %{"head" => %{"ref" => ctx.task.branch}}
        })

      assert %Delivery{status: "processed", outcome: "correção pedida pelo review"} =
               deliver(ctx, "pull_request_review_rejected", review)

      task = Repo.reload!(ctx.task)
      assert task.status == :running
      assert List.last(task.stages).name =~ "Correção"
    end

    test "a review on a task still running waits; an approval changes nothing", ctx do
      rejected =
        payload("pull_request_review_rejected", %{
          "pull_request" => %{"head" => %{"ref" => ctx.task.branch}}
        })

      assert %Delivery{status: "ignored", outcome: outcome} =
               deliver(ctx, "pull_request_review_rejected", rejected)

      assert outcome =~ "em andamento"

      approved =
        payload("pull_request_review_approved", %{
          "pull_request" => %{"head" => %{"ref" => ctx.task.branch}}
        })

      assert %Delivery{status: "ignored", outcome: "review sem pedido de mudanças"} =
               deliver(ctx, "pull_request_review_approved", approved)
    end

    test "a merge is told on the issue", ctx do
      ctx.task |> Ecto.Changeset.change(status: :succeeded) |> Repo.update!()

      merged =
        payload("pull_request_closed_merged", %{
          "pull_request" => %{"head" => %{"ref" => ctx.task.branch}}
        })

      assert %Delivery{status: "processed", outcome: "pull request integrado"} =
               deliver(ctx, "pull_request", merged)

      assert %Task{issue_feedback: %{"merged" => true}} = Repo.reload!(ctx.task)
      assert Enum.any?(comments(ctx), &(&1["body"] =~ "integrado ✅"))
    end
  end
end
