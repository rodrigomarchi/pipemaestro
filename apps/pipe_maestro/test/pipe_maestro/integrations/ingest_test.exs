defmodule PipeMaestro.Integrations.IngestTest do
  use PipeMaestro.DataCase, async: true

  import PipeMaestro.Fixtures

  alias PipeMaestro.{FakeForgejo, Integrations, Jobs, Proposals, Repo, Runners, Tasks}
  alias PipeMaestro.Integrations.{Connection, Delivery, Ingest, IssueState}
  alias PipeMaestro.Tasks.Task

  @fixtures Path.expand("../../support/fixtures/forgejo", __DIR__)

  setup do
    workspace = workspace_fixture()
    user = member_fixture(workspace)
    fake = FakeForgejo.start(permissions: %{"ana" => "write", "rui" => "read"})

    FakeForgejo.put_issue(fake, "acme/app", %{
      "number" => 3,
      "title" => "Login quebra",
      "body" => "Com e-mail maiúsculo.",
      "labels" => ["bug", "pipemaestro"]
    })

    {runner, _token} = runner_fixture(workspace, user, %{name: "mac"})

    {:ok, runner} =
      Runners.record_hello(
        runner,
        hello_fixture(%{
          capabilities: ["scratch"],
          directories: [%{"name" => "app", "git" => true}]
        })
      )

    project = project_fixture(workspace)
    connection = connection_fixture(workspace)

    {:ok, repo} =
      Integrations.link_repo(
        connection,
        user,
        %{"full_name" => "acme/app", "project_id" => project.id},
        "https://pm.test/hook"
      )

    %{
      workspace: workspace,
      user: user,
      fake: fake,
      runner: runner,
      connection: connection,
      repo: repo,
      pipeline: pipeline_fixture(workspace, %{"name" => "Correção de bug"}),
      opts: [presence: fn _ -> MapSet.new([runner.id]) end]
    }
  end

  defp trigger(ctx, attrs) do
    {:ok, trigger} =
      Integrations.save_trigger(
        ctx.repo,
        ctx.user,
        Integrations.new_trigger(ctx.repo, ctx.user),
        attrs
      )

    trigger
  end

  defp payload(name, changes \\ %{}) do
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

  defp headers(type, id),
    do: %{"x-forgejo-event-type" => type, "x-forgejo-event" => type, "x-forgejo-delivery" => id}

  defp signed(ctx, type, id, payload) do
    body = JSON.encode!(payload)

    signature =
      :crypto.mac(:hmac, :sha256, Connection.webhook_secret(ctx.connection), body)
      |> Base.encode16(case: :lower)

    {Map.put(headers(type, id), "x-forgejo-signature", signature), body}
  end

  # Records and processes a delivery, without the async step.
  defp deliver(ctx, type, payload, id \\ nil) do
    id = id || "d-#{System.unique_integer([:positive])}"
    {headers, body} = signed(ctx, type, id, payload)
    {:ok, delivery} = Ingest.record_webhook(ctx.connection.id, headers, body)
    Ingest.process(delivery, ctx.opts)
  end

  defp proposal_jobs(ctx), do: Proposals.list(ctx.workspace, %{"kind" => "task"})

  describe "receiving a webhook" do
    test "records a signed delivery once and processes it", ctx do
      trigger(ctx, %{"kind" => "label", "label" => "pipemaestro"})
      Integrations.subscribe_deliveries(ctx.workspace)
      {headers, body} = signed(ctx, "issue_label", "d-1", payload("issue_label"))

      assert {:ok, %Delivery{status: "received"} = delivery} =
               Ingest.receive_webhook(ctx.connection.id, headers, body, ctx.opts)

      assert_receive {:delivery_updated, %Delivery{id: id, status: "processed"}}, 2_000
      assert id == delivery.id
      assert Ingest.receive_webhook(ctx.connection.id, headers, body, ctx.opts) == :duplicate
      assert [_one] = proposal_jobs(ctx)
    end

    test "refuses a bad signature and an unknown connection without recording", ctx do
      {headers, body} = signed(ctx, "issue_label", "d-2", payload("issue_label"))

      assert Ingest.receive_webhook(
               ctx.connection.id,
               %{headers | "x-forgejo-signature" => "00"},
               body,
               ctx.opts
             ) ==
               {:error, :bad_signature}

      assert Ingest.receive_webhook(Ecto.UUID.generate(), headers, body, ctx.opts) ==
               {:error, :not_found}

      assert Ingest.receive_webhook("nada", headers, body, ctx.opts) == {:error, :not_found}
      assert Repo.all(Delivery) == []
    end
  end

  describe "the label trigger" do
    setup ctx,
      do: %{
        trigger:
          trigger(ctx, %{
            "kind" => "label",
            "label" => "pipemaestro",
            "pipeline_id" => ctx.pipeline.id
          })
      }

    test "a label just added starts the triage, with auto approval and the issue's link", ctx do
      assert %Delivery{status: "processed", proposal_job_id: job_id, outcome: outcome} =
               deliver(ctx, "issue_label", payload("issue_label"))

      assert outcome =~ "triagem"
      job = Jobs.get_job!(ctx.workspace, job_id)
      input = Proposals.input(job)

      assert input["auto_approve"] == true
      assert input["pipeline_id"] == ctx.pipeline.id
      assert input["linked_repo_id"] == ctx.repo.id
      assert input["issue_number"] == 3
      assert input["issue_url"] == "https://forge.test/acme/app/issues/3"
      assert input["request"] =~ "Login quebra"
      assert job.created_by_user_id == ctx.user.id
    end

    test "when the agent is done, the task is created on its own, linked to the issue", ctx do
      %Delivery{proposal_job_id: job_id} = deliver(ctx, "issue_label", payload("issue_label"))
      {:ok, _} = Jobs.mark_started(ctx.runner, job_id)

      {:ok, _} =
        Jobs.finish_job(ctx.runner, job_id, %{
          "status" => "succeeded",
          "structured_output" => %{
            "analise" => "O login compara o e-mail sem normalizar.",
            "titulo" => "Normalizar o e-mail no login",
            "descricao" => "## Problema\n\nO login compara o e-mail com caixa.",
            "pipeline" => "outro",
            "pronta" => true,
            "perguntas" => []
          }
        })

      task = Repo.get_by!(Task, proposal_job_id: job_id)
      assert task.title == "Normalizar o e-mail no login"
      assert task.pipeline_id == ctx.pipeline.id
      assert {task.linked_repo_id, task.issue_number} == {ctx.repo.id, 3}
      assert task.issue_url == "https://forge.test/acme/app/issues/3"
      assert task.created_by_user_id == ctx.user.id
    end

    test "acknowledges on the issue: a reaction and the triage label", ctx do
      deliver(ctx, "issue_label", payload("issue_label"))
      repo = FakeForgejo.repo(ctx.fake, "acme/app")

      assert {:issue, 3, "eyes"} in repo.reactions
      assert "pipemaestro:triando" in Enum.map(repo.issues[3]["labels"], & &1["name"])
    end

    test "a label that was already there does not fire again", ctx do
      deliver(ctx, "issue_label", payload("issue_label"))
      Repo.update_all(Jobs.Job, set: [status: :succeeded])

      assert %Delivery{status: "ignored", outcome: "nenhum gatilho casou"} =
               deliver(ctx, "issue_label", payload("issue_label"))
    end

    test "removing and adding the label again fires again once the first ended", ctx do
      deliver(ctx, "issue_label", payload("issue_label"))
      Repo.update_all(Jobs.Job, set: [status: :succeeded])

      without = payload("issue_label", %{"issue" => %{"labels" => [%{"name" => "bug"}]}})
      assert %Delivery{status: "ignored"} = deliver(ctx, "issue_label", without)
      assert %Delivery{status: "processed"} = deliver(ctx, "issue_label", payload("issue_label"))
      assert length(proposal_jobs(ctx)) == 2
    end

    test "an issue with its triage running is left alone", ctx do
      deliver(ctx, "issue_label", payload("issue_label"))
      without = payload("issue_label", %{"issue" => %{"labels" => [%{"name" => "bug"}]}})
      deliver(ctx, "issue_label", without)

      assert %Delivery{status: "ignored", outcome: outcome} =
               deliver(ctx, "issue_label", payload("issue_label"))

      assert outcome =~ "em andamento"
    end

    test "a direct task starts the pipeline with the issue's text, linked to it", ctx do
      Integrations.save_trigger(ctx.repo, ctx.user, ctx.trigger, %{"mode" => "task"})

      assert %Delivery{status: "processed", task_id: task_id} =
               deliver(ctx, "issue_label", payload("issue_label"))

      task = Repo.get!(Task, task_id)

      assert task.title == "Login quebra"
      assert task.prompt =~ "Com e-mail maiúsculo."
      assert task.pipeline_id == ctx.pipeline.id
      assert task.directory == "app"
      assert {task.linked_repo_id, task.issue_number} == {ctx.repo.id, 3}
      assert task.issue_url == "https://forge.test/acme/app/issues/3"
      assert Tasks.active_for_issue?(ctx.workspace, task.issue_url)
    end

    test "uses the issue as the host has it now: a closed one is skipped", ctx do
      Agent.update(ctx.fake, &put_in(&1, [:repos, "acme/app", :issues, 3, "state"], "closed"))

      assert %Delivery{status: "ignored", outcome: "a issue foi fechada"} =
               deliver(ctx, "issue_label", payload("issue_label"))
    end
  end

  describe "waiting for a runner" do
    test "a delivery without a runner online waits, and the retry processes it", ctx do
      trigger(ctx, %{"kind" => "label", "label" => "pipemaestro"})
      {headers, body} = signed(ctx, "issue_label", "d-wait", payload("issue_label"))
      {:ok, delivery} = Ingest.record_webhook(ctx.connection.id, headers, body)

      assert %Delivery{status: "waiting_runner", outcome: outcome} =
               Ingest.process(delivery, presence: fn _ -> MapSet.new() end)

      assert outcome =~ "nenhum runner online"

      assert %Delivery{status: "processed", attempts: 2} =
               Ingest.process(Repo.reload!(delivery), ctx.opts)
    end
  end

  describe "the comment trigger" do
    setup ctx, do: %{trigger: trigger(ctx, %{"kind" => "comment", "command" => "/pipemaestro"})}

    test "a writer's command starts the triage", ctx do
      assert %Delivery{status: "processed"} =
               deliver(ctx, "issue_comment", payload("issue_comment"))
    end

    test "names the pipeline after the command", ctx do
      comment =
        payload("issue_comment", %{
          "comment" => %{"body" => "/pipemaestro correção de bug\nPor favor."}
        })

      %Delivery{proposal_job_id: job_id} = deliver(ctx, "issue_comment", comment)

      assert Proposals.input(Jobs.get_job!(ctx.workspace, job_id))["pipeline_id"] ==
               ctx.pipeline.id
    end

    test "an unknown pipeline is said so", ctx do
      comment = payload("issue_comment", %{"comment" => %{"body" => "/pipemaestro inexistente"}})

      assert %Delivery{status: "ignored", outcome: outcome} =
               deliver(ctx, "issue_comment", comment)

      assert outcome =~ "inexistente"
    end

    test "a reader's command and a plain comment are ignored", ctx do
      reader =
        payload("issue_comment", %{
          "comment" => %{"user" => %{"login" => "rui"}},
          "sender" => %{"login" => "rui"}
        })

      assert %Delivery{status: "ignored", outcome: "o autor não tem permissão de escrita"} =
               deliver(ctx, "issue_comment", reader)

      plain = payload("issue_comment", %{"comment" => %{"body" => "Alguém viu isso?"}})

      assert %Delivery{status: "ignored", outcome: "nenhum gatilho casou"} =
               deliver(ctx, "issue_comment", plain)
    end

    test "the bot's own comments are ignored", ctx do
      own = payload("issue_comment", %{"sender" => %{"login" => "pipemaestro-bot"}})

      assert %Delivery{status: "ignored", outcome: "evento do próprio bot"} =
               deliver(ctx, "issue_comment", own)
    end
  end

  describe "the new issue trigger" do
    test "fires for a writer and not for an outsider", ctx do
      trigger(ctx, %{"kind" => "opened"})

      assert %Delivery{status: "processed"} = deliver(ctx, "issues", payload("issues_opened"))

      FakeForgejo.put_issue(ctx.fake, "acme/app", %{
        "number" => 4,
        "user" => %{"login" => "estranho"}
      })

      outsider =
        payload("issues_opened", %{
          "number" => 4,
          "issue" => %{"number" => 4, "user" => %{"login" => "estranho"}}
        })

      assert %Delivery{status: "ignored", outcome: "o autor não tem permissão de escrita"} =
               deliver(ctx, "issues", outsider)
    end

    test "with any author it fires for an outsider too", ctx do
      trigger(ctx, %{"kind" => "opened", "author_policy" => "anyone", "confirm_anyone" => "true"})

      FakeForgejo.put_issue(ctx.fake, "acme/app", %{
        "number" => 4,
        "user" => %{"login" => "estranho"}
      })

      outsider =
        payload("issues_opened", %{
          "number" => 4,
          "issue" => %{"number" => 4, "user" => %{"login" => "estranho"}}
        })

      assert %Delivery{status: "processed"} = deliver(ctx, "issues", outsider)
    end

    test "stops at the hourly limit", ctx do
      trigger(ctx, %{"kind" => "opened", "max_per_hour" => 1})
      assert %Delivery{status: "processed"} = deliver(ctx, "issues", payload("issues_opened"))

      FakeForgejo.put_issue(ctx.fake, "acme/app", %{"number" => 4})
      second = payload("issues_opened", %{"number" => 4, "issue" => %{"number" => 4}})

      assert %Delivery{status: "ignored", outcome: "o gatilho chegou ao limite por hora"} =
               deliver(ctx, "issues", second)
    end
  end

  describe "what is not for a trigger" do
    test "an unlinked repository, an unused event and a disabled trigger", ctx do
      trigger(ctx, %{"kind" => "label", "label" => "pipemaestro", "enabled" => "false"})

      other = payload("issue_label", %{"repository" => %{"full_name" => "acme/outro"}})

      assert %Delivery{status: "ignored", outcome: "repositório não vinculado"} =
               deliver(ctx, "issue_label", other)

      assert %Delivery{status: "ignored", outcome: "evento sem uso: push"} =
               deliver(ctx, "push", payload("push"))

      assert %Delivery{status: "ignored", outcome: "nenhum gatilho casou"} =
               deliver(ctx, "issue_label", payload("issue_label"))
    end

    test "keeps the issue's labels to tell the next one added", ctx do
      deliver(ctx, "issue_label", payload("issue_label"))

      assert %IssueState{labels: ["bug", "pipemaestro"]} =
               Repo.get_by!(IssueState, repo_id: ctx.repo.id, number: 3)
    end
  end

  describe "replaying" do
    test "a delivery processes again as a new one", ctx do
      %Delivery{status: "ignored"} = ignored = deliver(ctx, "issue_label", payload("issue_label"))
      trigger(ctx, %{"kind" => "label", "label" => "pipemaestro"})
      Repo.delete_all(IssueState)

      assert {:ok, %Delivery{source: "replay", status: "processed"}} =
               Ingest.replay(ignored, ctx.user, ctx.opts)
    end
  end
end
