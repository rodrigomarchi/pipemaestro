defmodule PipeMaestro.Integrations.GitHubTest do
  use PipeMaestro.DataCase, async: true

  import PipeMaestro.Fixtures

  alias PipeMaestro.{FakeGitHub, Integrations, Repo, Runners, Tasks}

  alias PipeMaestro.Integrations.{
    Connection,
    Credentials,
    Delivery,
    Event,
    Feedback,
    GitHub,
    Ingest,
    Reconciler
  }

  alias PipeMaestro.TaskSources.Origin

  @secret "segredo-do-app"

  defp sign(body),
    do: "sha256=" <> (:crypto.mac(:hmac, :sha256, @secret, body) |> Base.encode16(case: :lower))

  defp headers(event, id \\ "gh-1"), do: %{"x-github-event" => event, "x-github-delivery" => id}

  defp github_connection(workspace, installation \\ "99") do
    {:ok, connection} =
      Integrations.create_connection(workspace, member_fixture(workspace), %{
        "name" => "GitHub",
        "provider" => "github",
        "auth_kind" => "github_app"
      })

    connection
    |> Connection.installation_changeset(installation)
    |> Ecto.Changeset.change(status: "active")
    |> Repo.update!()
  end

  describe "webhooks" do
    test "the App's signature and the delivery's id" do
      body = ~s({"action":"opened"})
      assert GitHub.app_signed?(%{"x-hub-signature-256" => sign(body)}, body)
      refute GitHub.app_signed?(%{"x-hub-signature-256" => sign(body <> " ")}, body)
      refute GitHub.app_signed?(%{}, body)
      assert GitHub.delivery_id(headers("issues")) == "gh-1"
    end

    test "normalizes issues, comments, reviews and closed pull requests" do
      repo = %{"full_name" => "Acme/App"}

      issue = %{
        "number" => 3,
        "title" => "T",
        "body" => "B",
        "html_url" => "https://github.test/acme/app/issues/3",
        "user" => %{"login" => "ana"},
        "labels" => [%{"name" => "pipemaestro"}]
      }

      assert {:ok,
              %Event{kind: :issue_opened, repo: "acme/app", issue: %{number: 3, is_pull: false}}} =
               GitHub.parse_event(headers("issues"), %{
                 "action" => "opened",
                 "issue" => issue,
                 "repository" => repo
               })

      assert {:ok, %Event{kind: :issue_labels_changed, issue: %{labels: ["pipemaestro"]}}} =
               GitHub.parse_event(headers("issues"), %{
                 "action" => "labeled",
                 "issue" => issue,
                 "repository" => repo
               })

      pr_issue = Map.put(issue, "pull_request", %{"url" => "x"})

      assert {:ok,
              %Event{
                kind: :issue_comment,
                issue: %{is_pull: true},
                comment: %{id: 5, author: "bia"}
              }} =
               GitHub.parse_event(headers("issue_comment"), %{
                 "action" => "created",
                 "issue" => pr_issue,
                 "comment" => %{
                   "id" => 5,
                   "body" => "/pipemaestro seguir",
                   "user" => %{"login" => "bia"}
                 },
                 "repository" => repo
               })

      pr = %{"number" => 7, "head" => %{"ref" => "cp/x"}, "merged" => true, "node_id" => "PR_7"}

      assert {:ok, %Event{kind: :pr_review, review: %{state: :rejected, body: "Falta teste"}}} =
               GitHub.parse_event(headers("pull_request_review"), %{
                 "action" => "submitted",
                 "review" => %{"state" => "changes_requested", "body" => "Falta teste"},
                 "pull_request" => pr,
                 "repository" => repo
               })

      assert {:ignore, _} =
               GitHub.parse_event(headers("pull_request_review"), %{
                 "action" => "submitted",
                 "review" => %{"state" => "commented"},
                 "pull_request" => pr,
                 "repository" => repo
               })

      assert {:ok, %Event{kind: :pr_closed, pr: %{merged: true, head: "cp/x"}}} =
               GitHub.parse_event(headers("pull_request"), %{
                 "action" => "closed",
                 "pull_request" => pr,
                 "repository" => repo
               })

      assert {:ok, %Event{pr: %{merged_at: ~U[2026-11-05 10:00:00Z]}}} =
               GitHub.parse_event(headers("pull_request"), %{
                 "action" => "closed",
                 "pull_request" => Map.put(pr, "merged_at", "2026-11-05T10:00:00Z"),
                 "repository" => repo
               })

      assert {:ignore, "evento sem uso: push"} = GitHub.parse_event(headers("push"), %{})
    end
  end

  describe "the App's credentials" do
    setup do
      %{
        fake: FakeGitHub.start(permissions: %{"ana" => "maintain"}),
        workspace: workspace_fixture()
      }
    end

    test "mints an installation token with a JWT the App signed, and keeps it", ctx do
      connection = github_connection(ctx.workspace)

      assert {:ok, client} = Credentials.client(connection)
      assert {:ok, %{login: "pipemaestro-test[bot]"}} = GitHub.whoami(client)
      assert {:ok, _again} = Credentials.client(Repo.reload!(connection))
      assert [%{installation_id: 99, repository_ids: nil}] = FakeGitHub.tokens(ctx.fake)
    end

    test "a job's git credential is narrowed to its repository, to write code", ctx do
      connection = github_connection(ctx.workspace)

      assert {:ok,
              %{
                "host" => "github.test",
                "username" => "x-access-token",
                "password" => "ghs_" <> _
              }} =
               Credentials.git_credential(connection, %{external_id: "123"})

      assert [%{repository_ids: [123], permissions: %{"contents" => "write"}}] =
               FakeGitHub.tokens(ctx.fake)
    end

    test "an installation GitHub does not know is an error", ctx do
      connection = github_connection(ctx.workspace, "7")
      assert {:error, message} = Credentials.client(connection)
      assert message =~ "404"
    end

    test "confirms the installation of whoever installed it", ctx do
      {:ok, connection} =
        Integrations.create_connection(ctx.workspace, member_fixture(ctx.workspace), %{
          "name" => "GitHub",
          "provider" => "github",
          "auth_kind" => "github_app"
        })

      assert connection.base_url == "https://github.test"
      assert connection.status == "pending"

      assert {:error, "quem entrou no GitHub não administra essa instalação"} =
               Integrations.confirm_installation(connection, "55", "code-1")

      assert {:error, _} = Integrations.confirm_installation(connection, "99", "codigo-errado")

      assert {:ok,
              %Connection{
                status: "active",
                external_account_id: "99",
                bot_login: "pipemaestro-test[bot]"
              }} =
               Integrations.confirm_installation(connection, "99", "code-1")

      assert Integrations.github_connection("99").id == connection.id

      {:ok, other} =
        Integrations.create_connection(workspace_fixture(), member_fixture(ctx.workspace), %{
          "name" => "GitHub",
          "provider" => "github",
          "auth_kind" => "github_app"
        })

      assert {:error, "essa instalação já está ligada a outra conexão"} =
               Integrations.confirm_installation(other, "99", "code-1")
    end

    test "someone who only sees an installation cannot take it", ctx do
      FakeGitHub.start(
        user_installations: %{
          99 => %{"type" => "Organization", "login" => "acme"},
          100 => %{"type" => "User", "login" => "outra-pessoa"},
          101 => %{"type" => "User", "login" => "ana"}
        },
        memberships: %{"acme" => "member"}
      )

      {:ok, connection} =
        Integrations.create_connection(ctx.workspace, member_fixture(ctx.workspace), %{
          "name" => "GitHub",
          "provider" => "github",
          "auth_kind" => "github_app"
        })

      assert {:error, _} = Integrations.confirm_installation(connection, "99", "code-1")
      assert {:error, _} = Integrations.confirm_installation(connection, "100", "code-1")

      assert {:ok, %Connection{external_account_id: "101"}} =
               Integrations.confirm_installation(connection, "101", "code-1")
    end

    test "maps permissions and lists the installation's repositories", ctx do
      {:ok, client} = Credentials.client(github_connection(ctx.workspace))

      assert GitHub.permission(client, "acme/app", "ana") == {:ok, :write}
      assert GitHub.permission(client, "acme/app", "estranho") == {:ok, :none}

      assert {:ok, [%{full_name: "acme/app", default_branch: "main"}], false} =
               GitHub.list_repos(client, "acme", 1)

      assert {:ok, "app"} = GitHub.create_webhook(client, "acme/app", "u", "s")
    end
  end

  describe "the App's webhook" do
    setup do
      FakeGitHub.start()
      workspace = workspace_fixture()
      %{workspace: workspace, connection: github_connection(workspace)}
    end

    test "goes to the installation's connection, once", ctx do
      Integrations.subscribe_deliveries(ctx.workspace)

      body =
        JSON.encode!(%{
          "action" => "opened",
          "installation" => %{"id" => 99},
          "repository" => %{"full_name" => "acme/nada"}
        })

      headers = Map.put(headers("issues", "gh-9"), "x-hub-signature-256", sign(body))

      assert {:ok, %Delivery{connection_id: connection_id}} =
               Ingest.receive_app_webhook(headers, body)

      assert connection_id == ctx.connection.id
      assert_receive {:delivery_updated, %Delivery{status: "ignored"}}, 2_000
      assert Ingest.receive_app_webhook(headers, body) == :duplicate
    end

    test "a removed installation stops its connection; an unsigned delivery is refused", ctx do
      body = JSON.encode!(%{"action" => "deleted", "installation" => %{"id" => 99}})
      headers = Map.put(headers("installation"), "x-hub-signature-256", sign(body))

      assert {:ok, :installation} = Ingest.receive_app_webhook(headers, body)
      assert %Connection{status: "error"} = Repo.reload!(ctx.connection)

      assert {:error, :bad_signature} =
               Ingest.receive_app_webhook(%{headers | "x-hub-signature-256" => "sha256=00"}, body)
    end

    test "a GitHub connection takes no webhook of its own", ctx do
      assert Ingest.record_webhook(ctx.connection.id, %{}, "{}") == {:error, :not_found}
    end

    test "another installation's event is acknowledged and dropped" do
      body = JSON.encode!(%{"action" => "opened", "installation" => %{"id" => 1}})
      headers = Map.put(headers("issues"), "x-hub-signature-256", sign(body))
      assert {:ok, :ignored} = Ingest.receive_app_webhook(headers, body)
    end
  end

  describe "merging a pull request on GitHub" do
    setup do
      pull = %{
        "number" => 1,
        "node_id" => "PR_1",
        "state" => "open",
        "draft" => false,
        "title" => "Corrige",
        "head" => %{"ref" => "cp/x", "sha" => "abc"},
        "base" => %{"ref" => "main"},
        "html_url" => "https://github.test/acme/app/pull/1"
      }

      fake = FakeGitHub.start(repos: %{"acme/app" => %{pulls: [pull]}})
      {:ok, client} = Credentials.client(github_connection(workspace_fixture()))
      %{fake: fake, client: client}
    end

    test "reads the pull request with its head and whether it merges", %{client: client} do
      assert {:ok, %{number: 1, head_sha: "abc", base: "main", mergeable: true, merged: false}} =
               GitHub.get_pr(client, "acme/app", 1)
    end

    test "checks are the commit statuses and the other apps' check runs", ctx do
      FakeGitHub.put_status(ctx.fake, "acme/app", "abc", "ci/build", "pending")
      FakeGitHub.put_status(ctx.fake, "acme/app", "abc", "ci/build", "success")
      FakeGitHub.put_check_run(ctx.fake, "acme/app", "abc", "test", "failure")
      FakeGitHub.put_check_run(ctx.fake, "acme/app", "abc", "lint", nil)
      FakeGitHub.put_check_run(ctx.fake, "acme/app", "abc", "docs", "skipped")
      FakeGitHub.put_check_run(ctx.fake, "acme/app", "other", "test", "success")

      assert {:ok, checks} = GitHub.pr_checks(ctx.client, "acme/app", "abc")

      assert Enum.map(checks, &{&1.name, &1.state}) == [
               {"ci/build", :success},
               {"test", :failure},
               {"lint", :pending},
               {"docs", :success}
             ]
    end

    test "lists the pull request's commits, every page", ctx do
      commits = for n <- 1..45, do: PipeMaestro.FakeForgejo.commit_json("c#{n}")
      FakeGitHub.edit_pull(ctx.fake, "acme/app", 1, &Map.put(&1, "commits", commits))

      assert {:ok, listed} = GitHub.pr_commits(ctx.client, "acme/app", 1)
      assert Enum.map(listed, & &1.sha) == Enum.map(1..45, &"c#{&1}")
      assert hd(listed) == %{sha: "c1", parents: ["base"], committed_at: ~U[2026-11-01 12:00:00Z]}
    end

    test "the pull request says when it was merged or closed", ctx do
      FakeGitHub.edit_pull(
        ctx.fake,
        "acme/app",
        1,
        &Map.merge(&1, %{
          "state" => "closed",
          "merged" => true,
          "merged_at" => "2026-11-05T10:00:00Z",
          "closed_at" => "2026-11-05T10:00:00Z"
        })
      )

      assert {:ok, %{merged: true, merged_at: ~U[2026-11-05 10:00:00Z], closed_at: _}} =
               GitHub.get_pr(ctx.client, "acme/app", 1)
    end

    test "merges with the method, refused when the head moved", ctx do
      assert {:error, %{status: 409}} =
               GitHub.merge_pr(ctx.client, "acme/app", 1, %{method: "squash", sha: "old"})

      assert :ok = GitHub.merge_pr(ctx.client, "acme/app", 1, %{method: "squash", sha: "abc"})

      assert [%{"merged" => true, "merge" => %{"merge_method" => "squash", "sha" => "abc"}}] =
               FakeGitHub.repo(ctx.fake, "acme/app").pulls
    end
  end

  describe "feedback on GitHub" do
    test "a stage is a check run and the draft is marked ready through GraphQL" do
      fake = FakeGitHub.start(permissions: %{"ana" => "write"})
      FakeGitHub.put_issue(fake, "acme/app", %{"number" => 3})
      workspace = workspace_fixture()
      user = member_fixture(workspace)
      {runner, _} = runner_fixture(workspace, user)

      {:ok, runner} =
        Runners.record_hello(
          runner,
          hello_fixture(%{directories: [%{"name" => "app", "git" => true}]})
        )

      connection = github_connection(workspace)
      project = project_fixture(runner, "app")

      {:ok, repo} =
        Integrations.link_repo(
          connection,
          user,
          %{"full_name" => "acme/app", "project_id" => project.id},
          "https://x"
        )

      assert repo.webhook_status == "managed"

      {:ok, task} =
        Tasks.create_task(
          user,
          workspace,
          %{
            "title" => "Corrige",
            "prompt" => "Corrija.",
            "pipeline_id" => pipeline_fixture(workspace, %{"delivery" => "pr"}).id,
            "project_id" => project.id
          },
          origin: %Origin{
            source: "git_issue",
            external_id: "https://github.test/acme/app/issues/3",
            url: "https://github.test/acme/app/issues/3",
            ref: %{"number" => 3},
            linked_repo_id: repo.id
          }
        )

      task |> Ecto.Changeset.change(head_sha: "abc") |> Repo.update!()
      assert Feedback.sync(task.id) == :ok

      fake_repo = FakeGitHub.repo(fake, "acme/app")

      assert [%{"name" => "pipemaestro/a", "head_sha" => "abc", "status" => "in_progress"}] =
               fake_repo.check_runs

      assert [%{"draft" => true, "node_id" => "PR_1"}] = fake_repo.pulls

      Repo.reload!(task) |> Ecto.Changeset.change(status: :succeeded) |> Repo.update!()
      assert Feedback.sync(task.id) == :ok
      assert FakeGitHub.state(fake).ready == ["PR_1"]

      # One check run per stage, updated as the task goes.
      runs = FakeGitHub.repo(fake, "acme/app").check_runs
      assert Enum.map(runs, & &1["name"]) == ["pipemaestro/a", "pipemaestro/b"]
      assert Enum.all?(runs, &(&1["conclusion"] == "success"))

      # A stopped stage offers to run it again; pressing it does.
      Repo.reload!(task)
      |> Ecto.Changeset.change(
        status: :awaiting_decision,
        current_stage: 1,
        decision_reason: "travou"
      )
      |> Repo.update!()

      Feedback.sync(task.id)

      stopped =
        Enum.find(FakeGitHub.repo(fake, "acme/app").check_runs, &(&1["name"] == "pipemaestro/b"))

      assert [%{"identifier" => "retry"}] = stopped["actions"]

      body =
        JSON.encode!(%{
          "action" => "requested_action",
          "installation" => %{"id" => 99},
          "repository" => %{"full_name" => "acme/app"},
          "sender" => %{"login" => "ana"},
          "check_run" => %{"head_sha" => "abc", "name" => "pipemaestro/b"},
          "requested_action" => %{"identifier" => "retry"}
        })

      Integrations.subscribe_deliveries(workspace)
      headers = Map.put(headers("check_run", "gh-retry"), "x-hub-signature-256", sign(body))
      {:ok, _} = Ingest.receive_app_webhook(headers, body)

      assert_receive {:delivery_updated,
                      %Delivery{status: "processed", outcome: "etapa refeita a pedido de ana"}},
                     2_000

      assert [%{decided_via: "GitHub: ana", action: :retry}] =
               Repo.preload(Repo.reload!(task), :decisions).decisions
    end
  end

  test "the reconciliation asks GitHub again for the deliveries that failed" do
    recent = DateTime.utc_now() |> DateTime.add(-3600) |> DateTime.to_iso8601()
    old = DateTime.utc_now() |> DateTime.add(-5 * 86_400) |> DateTime.to_iso8601()

    fake =
      FakeGitHub.start(
        deliveries: [
          %{"id" => 1, "guid" => "a", "status" => "OK", "delivered_at" => recent},
          %{
            "id" => 2,
            "guid" => "b",
            "status" => "Invalid HTTP Response: 502",
            "delivered_at" => recent
          },
          %{"id" => 3, "guid" => "c", "status" => "timed out", "delivered_at" => old},
          # Asked again already: not again.
          %{"id" => 4, "guid" => "d", "status" => "timed out", "delivered_at" => recent},
          %{
            "id" => 5,
            "guid" => "d",
            "status" => "timed out",
            "delivered_at" => recent,
            "redelivery" => true
          }
        ]
      )

    github_connection(workspace_fixture())

    assert %{redelivered: 1} = Reconciler.run(DateTime.utc_now())
    assert FakeGitHub.state(fake).attempts == [2]
  end
end
