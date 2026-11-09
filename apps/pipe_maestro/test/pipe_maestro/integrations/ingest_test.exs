defmodule PipeMaestro.Integrations.IngestTest do
  use PipeMaestro.DataCase, async: true

  import Ecto.Query
  import PipeMaestro.Fixtures

  alias PipeMaestro.{FakeForgejo, Integrations, Jobs, Proposals, Repo, Runners, Tasks}
  alias PipeMaestro.Integrations.{Connection, Delivery, Feedback, Ingest, IssueState, LinkedRepo}
  alias PipeMaestro.Projects.Project
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

    project = project_fixture(runner, "app")
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

  # What a background step left, once it shows.
  # Other tests run background work too: past a second, it stops waiting.
  defp background_done(tries \\ 50) do
    if Elixir.Task.Supervisor.children(PipeMaestro.Integrations.TaskSupervisor) != [] and
         tries > 0 do
      Process.sleep(20)
      background_done(tries - 1)
    end
  end

  defp eventually(read, done?, tries \\ 50) do
    value = read.()

    cond do
      done?.(value) -> value
      tries == 0 -> flunk("never happened: #{inspect(value)}")
      true -> Process.sleep(20) && eventually(read, done?, tries - 1)
    end
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

      assert input["origin"] == %{
               "source" => "git_issue",
               "external_id" => "https://forge.test/acme/app/issues/3",
               "url" => "https://forge.test/acme/app/issues/3",
               "ref" => %{"number" => 3},
               "linked_repo_id" => ctx.repo.id
             }

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
      assert {task.linked_repo_id, task.source_ref} == {ctx.repo.id, %{"number" => 3}}
      assert task.source_url == "https://forge.test/acme/app/issues/3"
      assert task.created_by_user_id == ctx.user.id

      # The triage's end is told in the background: it must not outlive the test.
      background_done()
    end

    test "a triage that is not ready asks its questions on the issue", ctx do
      %Delivery{proposal_job_id: job_id} = deliver(ctx, "issue_label", payload("issue_label"))
      {:ok, _} = Jobs.mark_started(ctx.runner, job_id)

      {:ok, _} =
        Jobs.finish_job(ctx.runner, job_id, %{
          "status" => "succeeded",
          "structured_output" => %{
            "analise" => "Falta saber o navegador.",
            "titulo" => "Normalizar o e-mail",
            "descricao" => "Detalhes.",
            "pipeline" => "Correção de bug",
            "pronta" => false,
            "perguntas" => ["Em qual navegador acontece?"]
          }
        })

      repo =
        eventually(fn -> FakeForgejo.repo(ctx.fake, "acme/app") end, &(length(&1.comments) == 2))

      assert [%{"body" => status}, %{"body" => body}] = repo.comments
      assert status =~ "a triagem terminou sem criar a tarefa"
      assert body =~ "Em qual navegador acontece?"
      assert body =~ "/proposals/#{job_id}"
      assert "pipemaestro:aguardando-decisao" in Enum.map(repo.issues[3]["labels"], & &1["name"])
      refute Repo.get_by(Task, proposal_job_id: job_id)
    end

    test "a triage that failed says so on the issue", ctx do
      %Delivery{proposal_job_id: job_id} = deliver(ctx, "issue_label", payload("issue_label"))
      {:ok, _} = Jobs.mark_started(ctx.runner, job_id)

      {:ok, _} =
        Jobs.finish_job(ctx.runner, job_id, %{"status" => "failed", "error" => "sem créditos"})

      repo =
        eventually(fn -> FakeForgejo.repo(ctx.fake, "acme/app") end, &(length(&1.comments) == 2))

      assert [_status, %{"body" => body}] = repo.comments
      assert body =~ "não terminou"
    end

    test "acknowledges on the issue: a reaction and the triage label", ctx do
      deliver(ctx, "issue_label", payload("issue_label"))
      repo = FakeForgejo.repo(ctx.fake, "acme/app")

      assert {:issue, 3, "eyes"} in repo.reactions
      assert "pipemaestro:triando" in Enum.map(repo.issues[3]["labels"], & &1["name"])
      assert [%{"body" => status}] = repo.comments
      assert status =~ "<!-- pipemaestro:status -->"
      assert status =~ "A IA está lendo a issue"
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
      assert {task.linked_repo_id, task.source_ref} == {ctx.repo.id, %{"number" => 3}}
      assert task.source_url == "https://forge.test/acme/app/issues/3"
      assert Tasks.active_for_source?(ctx.workspace, "git_issue", task.source_url)
    end

    test "a label added by someone without write access (an issue template) is ignored", ctx do
      template = payload("issue_label", %{"sender" => %{"login" => "estranho"}})

      assert %Delivery{status: "ignored", outcome: "o autor não tem permissão de escrita"} =
               deliver(ctx, "issue_label", template)

      assert proposal_jobs(ctx) == []
    end

    test "the task keeps the status comment written when the issue was taken", ctx do
      Integrations.save_trigger(ctx.repo, ctx.user, ctx.trigger, %{"mode" => "task"})
      %Delivery{task_id: task_id} = deliver(ctx, "issue_label", payload("issue_label"))

      assert Feedback.sync(task_id) == :ok
      assert [%{"body" => body}] = FakeForgejo.repo(ctx.fake, "acme/app").comments
      assert body =~ "pipeline Correção de bug"
    end

    test "uses the issue as the host has it now: a closed one is skipped", ctx do
      Agent.update(ctx.fake, &put_in(&1, [:repos, "acme/app", :issues, 3, "state"], "closed"))

      assert %Delivery{status: "ignored", outcome: "a issue foi fechada"} =
               deliver(ctx, "issue_label", payload("issue_label"))
    end
  end

  describe "where the work runs" do
    test "a repository left without a project waits, without spending the label", ctx do
      trigger(ctx, %{"kind" => "label", "label" => "pipemaestro"})
      project_id = ctx.repo.project_id
      Repo.update_all(from(r in LinkedRepo, where: r.id == ^ctx.repo.id), set: [project_id: nil])

      {headers, body} = signed(ctx, "issue_label", "d-sem-projeto", payload("issue_label"))
      {:ok, delivery} = Ingest.record_webhook(ctx.connection.id, headers, body)

      assert %Delivery{status: "waiting_runner", outcome: "o repositório não está ligado" <> _} =
               Ingest.process(delivery, ctx.opts)

      Repo.update_all(from(r in LinkedRepo, where: r.id == ^ctx.repo.id),
        set: [project_id: project_id]
      )

      assert %Delivery{status: "processed"} = Ingest.process(Repo.reload!(delivery), ctx.opts)
    end

    test "the project's runner offline is no reason to wait: the job waits for it", ctx do
      trigger(ctx, %{"kind" => "label", "label" => "pipemaestro"})

      offline = %{ctx | opts: [presence: fn _ -> MapSet.new() end]}

      assert %Delivery{status: "processed", proposal_job_id: job_id} =
               deliver(offline, "issue_label", payload("issue_label"))

      assert Jobs.get_job!(ctx.workspace, job_id).status == :queued
    end

    test "a project without a runner waits, and the retry processes it once it has one", ctx do
      trigger(ctx, %{"kind" => "label", "label" => "pipemaestro"})
      project = Repo.get!(Project, ctx.repo.project_id)
      project |> Ecto.Changeset.change(runner_id: nil) |> Repo.update!()

      {headers, body} = signed(ctx, "issue_label", "d-wait", payload("issue_label"))
      {:ok, delivery} = Ingest.record_webhook(ctx.connection.id, headers, body)

      assert %Delivery{status: "waiting_runner", outcome: outcome} =
               Ingest.process(delivery, ctx.opts)

      assert outcome =~ "não tem um runner"
      assert [%{"body" => waiting}] = FakeForgejo.repo(ctx.fake, "acme/app").comments
      assert waiting =~ "não tem um runner"

      project
      |> Ecto.Changeset.change()
      |> Ecto.Changeset.force_change(:runner_id, ctx.runner.id)
      |> Repo.update!()

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

    test "a command on a pull request is not a trigger", ctx do
      on_pull = payload("issue_comment_pull", %{"comment" => %{"body" => "/pipemaestro"}})

      assert %Delivery{status: "ignored", outcome: "nenhum gatilho casou"} =
               deliver(ctx, "pull_request_comment", on_pull)
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
