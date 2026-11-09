defmodule PipeMaestro.Integrations.ConversationTest do
  use PipeMaestro.DataCase, async: true

  import PipeMaestro.Fixtures

  alias PipeMaestro.{Audit, FakeForgejo, Integrations, Repo, Runners, Tasks}
  alias PipeMaestro.Integrations.{Connection, Delivery, Ingest, PrOutcome, PrOutcomes}
  alias PipeMaestro.Tasks.{Decision, Task}

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
    project = project_fixture(runner, "app")

    {:ok, repo} =
      Integrations.link_repo(
        connection,
        user,
        %{"full_name" => "acme/app", "project_id" => project.id},
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
          "project_id" => project.id,
          "issue_url" => "https://forge.test/acme/app/issues/3"
        },
        issue: %{linked_repo_id: repo.id, issue_number: 3}
      )

    %{
      workspace: workspace,
      user: user,
      fake: fake,
      connection: connection,
      task: task,
      repo: repo
    }
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

      assert [%{decided_via: "Forgejo: ana", action: :advance}] =
               Repo.preload(Repo.reload!(ctx.task), :decisions).decisions
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
    test "a review asking for changes on a finished task becomes a correction, with its line comments",
         ctx do
      ctx.task |> Ecto.Changeset.change(status: :succeeded) |> Repo.update!()

      Agent.update(ctx.fake, fn state ->
        put_in(state, [:repos, "acme/app", :reviews, 7], [
          %{"id" => 1, "state" => "APPROVED", "comments" => []},
          %{
            "id" => 2,
            "state" => "REQUEST_CHANGES",
            "comments" => [
              %{"path" => "lib/auth.ex", "position" => 12, "body" => "Normalize aqui."}
            ]
          }
        ])
      end)

      review =
        payload("pull_request_review_rejected", %{
          "pull_request" => %{"head" => %{"ref" => ctx.task.branch}}
        })

      assert %Delivery{status: "processed", outcome: "correção pedida pelo review"} =
               deliver(ctx, "pull_request_review_rejected", review)

      task = Repo.reload!(ctx.task)
      assert task.status == :running
      assert List.last(task.stages).name =~ "Correção"

      [correction] =
        Repo.all(
          from d in PipeMaestro.Tasks.Decision,
            where: d.task_id == ^task.id and d.action == :correct
        )

      assert correction.instructions =~ "Falta o teste do e-mail com espaço."
      assert correction.instructions =~ "`lib/auth.ex` (linha 12): Normalize aqui."
      assert correction.decided_via == "Forgejo: bia"
    end

    test "a review from someone without write access changes nothing", ctx do
      ctx.task |> Ecto.Changeset.change(status: :succeeded) |> Repo.update!()

      review =
        payload("pull_request_review_rejected", %{
          "pull_request" => %{"head" => %{"ref" => ctx.task.branch}},
          "sender" => %{"login" => "rui"}
        })

      assert %Delivery{status: "ignored", outcome: "o autor não tem permissão de escrita"} =
               deliver(ctx, "pull_request_review_rejected", review)

      assert Repo.reload!(ctx.task).status == :succeeded
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

  describe "the pull request's outcome" do
    setup ctx do
      FakeForgejo.put_pull(ctx.fake, "acme/app", %{
        "number" => 7,
        "state" => "open",
        "head" => %{"ref" => ctx.task.branch, "sha" => "p1"},
        "base" => %{"ref" => "main"},
        "html_url" => "https://forge.test/acme/app/pulls/7",
        "commits" => [FakeForgejo.commit_json("p1")]
      })

      # The pipeline delivered p1 on PR 7 and the task ended: it is ready,
      # with the pipeline's commits read.
      task = delivered(ctx.task)
      PrOutcomes.ready(task)
      :ok = PrOutcomes.observe(task.id)
      %{task: task}
    end

    defp delivered(task) do
      task
      |> Ecto.Changeset.change(
        status: :succeeded,
        head_sha: "p1",
        pr_url: "https://forge.test/acme/app/pulls/7",
        issue_feedback: %{"pr_number" => 7},
        # Before the merge the payloads below date (2026-11-05).
        finished_at: ~U[2026-11-04 10:00:00Z]
      )
      |> Repo.update!()
    end

    defp pr_payload(ctx, name, changes \\ %{}) do
      payload(name, %{
        "pull_request" => Map.merge(%{"head" => %{"ref" => ctx.task.branch}}, changes)
      })
    end

    defp merge(ctx),
      do:
        deliver(
          ctx,
          "pull_request",
          pr_payload(ctx, "pull_request_closed_merged", %{
            "merged_at" => "2026-11-05T10:00:00Z",
            "closed_at" => "2026-11-05T10:00:00Z"
          })
        )

    defp outcome(ctx), do: PrOutcomes.get(ctx.task.id)

    test "a commit the pipeline did not push, then the merge: accepted with changes", ctx do
      FakeForgejo.edit_pull(
        ctx.fake,
        "acme/app",
        7,
        &Map.put(&1, "commits", [FakeForgejo.commit_json("p1"), FakeForgejo.commit_json("h1")])
      )

      assert %Delivery{status: "processed", outcome: "pull request integrado"} = merge(ctx)

      assert %{
               state: "merged",
               merged_at: ~U[2026-11-05 10:00:00Z],
               human_shas: ["h1"],
               pipeline_shas: ["p1"],
               commits_final: true
             } = outcome(ctx)

      assert PrOutcome.classify(outcome(ctx)) == :accepted_changed
    end

    test "merged as the pipeline left it: accepted without changes", ctx do
      assert %Delivery{status: "processed"} = merge(ctx)
      assert PrOutcome.classify(outcome(ctx)) == :accepted_clean
      assert DateTime.diff(outcome(ctx).merged_at, outcome(ctx).ready_at) > 0
    end

    test "closed without merging is recorded, and starts nothing", ctx do
      closed =
        pr_payload(ctx, "pull_request_closed", %{"closed_at" => "2026-11-06T09:00:00Z"})

      assert %Delivery{status: "processed", outcome: "pull request fechado sem integrar"} =
               deliver(ctx, "pull_request", closed)

      assert %{state: "closed", closed_at: ~U[2026-11-06 09:00:00Z], merged_at: nil} =
               outcome(ctx)

      assert PrOutcome.classify(outcome(ctx)) == :closed

      task = Repo.reload!(ctx.task)
      assert task.status == :succeeded
      assert length(task.stages) == 2
    end

    test "a review that became a correction counts as a round, once, and changes the PR",
         ctx do
      review = pr_payload(ctx, "pull_request_review_rejected")

      assert %Delivery{status: "processed", outcome: "correção pedida pelo review"} =
               delivery = deliver(ctx, "pull_request_review_rejected", review)

      assert %{review_rounds: 1} = outcome(ctx)

      assert [%{action: :correct, origin: :review}] =
               Repo.all(from d in Decision, where: d.task_id == ^ctx.task.id)

      # The correction ends; the same review processed again (the
      # reconciliation, a person's replay) is not a second round.
      delivered(Repo.reload!(ctx.task))

      assert %Delivery{status: "ignored", outcome: "review já aplicado"} =
               Ingest.process(Repo.reload!(delivery))

      assert {:ok, %Delivery{status: "ignored", outcome: "review já aplicado"}} =
               Ingest.replay(Repo.reload!(delivery), ctx.user)

      assert %{review_rounds: 1} = outcome(ctx)
      assert Repo.aggregate(from(d in Decision, where: d.task_id == ^ctx.task.id), :count) == 1

      assert %Delivery{status: "processed"} = merge(ctx)
      assert %{human_shas: []} = outcome(ctx)
      assert PrOutcome.classify(outcome(ctx)) == :accepted_changed
    end

    test "a correction a person asks for in a comment is no review round", ctx do
      assert %Delivery{status: "processed"} =
               comment(ctx, "/pipemaestro corrigir falta o teste do espaço")

      assert %{review_rounds: 0} = outcome(ctx)

      assert [%{action: :correct, origin: :person}] =
               Repo.all(from d in Decision, where: d.task_id == ^ctx.task.id)
    end

    test "the same merge delivered again changes nothing", ctx do
      FakeForgejo.edit_pull(
        ctx.fake,
        "acme/app",
        7,
        &Map.put(&1, "commits", [FakeForgejo.commit_json("p1"), FakeForgejo.commit_json("h1")])
      )

      delivery = merge(ctx)
      before = outcome(ctx)

      Ingest.process(Repo.reload!(delivery))
      {:ok, _copy} = Ingest.replay(Repo.reload!(delivery), ctx.user)
      :ok = PrOutcomes.observe(ctx.task.id)

      after_all = outcome(ctx)
      assert after_all.merged_at == before.merged_at
      assert after_all.human_shas == ["h1"]
      assert after_all.pipeline_shas == ["p1"]
      assert after_all.review_rounds == before.review_rounds
    end
  end
end
