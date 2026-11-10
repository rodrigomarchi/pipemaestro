defmodule PipeMaestro.Integrations.ForgejoTest do
  use ExUnit.Case, async: true

  alias PipeMaestro.FakeForgejo
  alias PipeMaestro.Integrations.{Client, Event, Forgejo}

  @fixtures Path.expand("../../support/fixtures/forgejo", __DIR__)

  defp fixture(name),
    do: @fixtures |> Path.join(name <> ".json") |> File.read!() |> JSON.decode!()

  defp headers(type, event \\ nil),
    do: %{
      "x-forgejo-event" => event || type,
      "x-forgejo-event-type" => type,
      "x-forgejo-delivery" => "d-1"
    }

  defp client(token \\ "tok"), do: Forgejo.client(FakeForgejo.base_url(), "token " <> token)

  describe "verify_signature/3" do
    test "takes the hex HMAC of the raw body and nothing else" do
      body = ~s({"action":"opened"})
      signature = :crypto.mac(:hmac, :sha256, "segredo", body) |> Base.encode16(case: :lower)

      assert Forgejo.verify_signature(%{"x-forgejo-signature" => signature}, body, "segredo")

      refute Forgejo.verify_signature(
               %{"x-forgejo-signature" => signature},
               body <> " ",
               "segredo"
             )

      refute Forgejo.verify_signature(%{"x-forgejo-signature" => signature}, body, "outro")
      refute Forgejo.verify_signature(%{"x-forgejo-signature" => ""}, body, "segredo")
      refute Forgejo.verify_signature(%{}, body, "segredo")
    end

    test "reads the delivery id" do
      assert Forgejo.delivery_id(headers("issues")) == "d-1"
      assert Forgejo.delivery_id(%{}) == nil
    end
  end

  describe "parse_event/2" do
    test "an opened issue" do
      assert {:ok, %Event{kind: :issue_opened, repo: "acme/app", sender: "ana", issue: issue}} =
               Forgejo.parse_event(headers("issues"), fixture("issues_opened"))

      assert issue.number == 3
      assert issue.title == "Login quebra com e-mail maiúsculo"
      assert issue.url == "https://forge.test/acme/app/issues/3"
      assert issue.author == "ana"
      assert issue.labels == []
      refute issue.is_pull
      assert issue.updated_at == ~U[2026-11-06 12:00:00Z]
    end

    test "a label change keeps the whole list of labels" do
      assert {:ok, %Event{kind: :issue_labels_changed, issue: %{labels: ["bug", "pipemaestro"]}}} =
               Forgejo.parse_event(headers("issue_label", "issues"), fixture("issue_label"))
    end

    test "a comment on an issue and on a pull request" do
      assert {:ok,
              %Event{
                kind: :issue_comment,
                comment: %{id: 77, body: "/pipemaestro", author: "ana"},
                issue: %{is_pull: false}
              }} =
               Forgejo.parse_event(headers("issue_comment"), fixture("issue_comment"))

      assert {:ok,
              %Event{
                kind: :issue_comment,
                issue: %{is_pull: true, number: 7},
                pr: %{number: 7, head: "cp/login-1a2b3c4d"}
              }} =
               Forgejo.parse_event(
                 headers("pull_request_comment", "issue_comment"),
                 fixture("issue_comment_pull")
               )
    end

    test "a closed issue" do
      assert {:ok, %Event{kind: :issue_closed, issue: %{number: 3}}} =
               Forgejo.parse_event(headers("issues"), fixture("issues_closed"))
    end

    test "reviews that approve and that ask for changes" do
      assert {:ok,
              %Event{
                kind: :pr_review,
                review: %{state: :approved, body: "Boa!"},
                pr: %{number: 7},
                sender: "bia"
              }} =
               Forgejo.parse_event(
                 headers("pull_request_review_approved", "pull_request_approved"),
                 fixture("pull_request_review_approved")
               )

      assert {:ok,
              %Event{
                kind: :pr_review,
                review: %{state: :rejected, body: "Falta o teste do e-mail com espaço."}
              }} =
               Forgejo.parse_event(
                 headers("pull_request_review_rejected", "pull_request_rejected"),
                 fixture("pull_request_review_rejected")
               )
    end

    test "a pull request closed with and without merge" do
      assert {:ok,
              %Event{kind: :pr_closed, pr: %{number: 7, merged: true, head: "cp/login-1a2b3c4d"}}} =
               Forgejo.parse_event(headers("pull_request"), fixture("pull_request_closed_merged"))

      assert {:ok, %Event{kind: :pr_closed, pr: %{merged: false}}} =
               Forgejo.parse_event(headers("pull_request"), fixture("pull_request_closed"))
    end

    test "a closed pull request brings when it was merged or closed" do
      merged =
        put_in(
          fixture("pull_request_closed_merged"),
          ["pull_request", "merged_at"],
          "2026-11-05T10:00:00Z"
        )

      assert {:ok, %Event{pr: %{merged_at: ~U[2026-11-05 10:00:00Z]}}} =
               Forgejo.parse_event(headers("pull_request"), merged)

      closed =
        put_in(
          fixture("pull_request_closed"),
          ["pull_request", "closed_at"],
          "2026-11-06T09:00:00Z"
        )

      assert {:ok, %Event{pr: %{merged_at: nil, closed_at: ~U[2026-11-06 09:00:00Z]}}} =
               Forgejo.parse_event(headers("pull_request"), closed)
    end

    test "ignores what the platform does not use" do
      assert {:ignore, "evento sem uso: push"} =
               Forgejo.parse_event(headers("push"), fixture("push"))

      assert {:ignore, _} =
               Forgejo.parse_event(headers("issues"), %{
                 fixture("issues_opened")
                 | "action" => "milestoned"
               })
    end
  end

  describe "the API" do
    setup do
      %{
        fake:
          FakeForgejo.start(
            repos: %{"acme/app" => %{}, "acme/site" => %{}, "outra/lib" => %{}},
            permissions: %{"ana" => "write", "rui" => "read", "acme" => "owner"}
          )
      }
    end

    test "who the token is and the server's version" do
      assert Forgejo.whoami(client()) == {:ok, %{login: "pipemaestro-bot", id: 7}}
      assert Forgejo.version(client()) == {:ok, "17.0.1+gitea-1.22.0"}
      assert {:error, %{status: 401}} = Forgejo.whoami(client("errado"))
    end

    test "lists the repositories by query, a page at a time", %{fake: _fake} do
      assert {:ok, [%{full_name: "acme/app"}, %{full_name: "acme/site"}], false} =
               Forgejo.list_repos(client(), "acme", 1)

      assert {:ok, [_one], true} = Forgejo.list_repos(client(), "", 1, limit: 1)

      assert {:ok, %{full_name: "acme/app", default_branch: "main", id: _}} =
               Forgejo.get_repo(client(), "acme/app")

      assert {:error, %{status: 404}} = Forgejo.get_repo(client(), "acme/nada")
    end

    test "maps a user's permission" do
      assert Forgejo.permission(client(), "acme/app", "acme") == {:ok, :admin}
      assert Forgejo.permission(client(), "acme/app", "ana") == {:ok, :write}
      assert Forgejo.permission(client(), "acme/app", "rui") == {:ok, :read}
      assert Forgejo.permission(client(), "acme/app", "estranho") == {:ok, :none}
    end

    test "creates only the labels that are missing", %{fake: fake} do
      labels = [
        %{name: "pipemaestro", color: "1d76db", description: "a"},
        %{name: "pipemaestro:pronto", color: "0e8a16", description: "b"}
      ]

      assert Forgejo.ensure_labels(client(), "acme/app", labels) == :ok
      assert Forgejo.ensure_labels(client(), "acme/app", labels) == :ok

      assert fake |> FakeForgejo.repo("acme/app") |> Map.fetch!(:labels) |> Enum.map(& &1["name"]) ==
               ["pipemaestro", "pipemaestro:pronto"]

      assert Enum.count(
               FakeForgejo.calls(fake),
               &(&1 == {"POST", "/api/v1/repos/acme/app/labels"})
             ) == 2
    end

    test "reads one issue and lists the open ones by update and label", %{fake: fake} do
      FakeForgejo.put_issue(fake, "acme/app", %{
        "number" => 1,
        "labels" => ["pipemaestro"],
        "updated_at" => "2026-11-06T10:00:00Z"
      })

      FakeForgejo.put_issue(fake, "acme/app", %{
        "number" => 2,
        "labels" => ["pipemaestro"],
        "updated_at" => "2026-11-06T13:00:00Z"
      })

      FakeForgejo.put_issue(fake, "acme/app", %{
        "number" => 3,
        "updated_at" => "2026-11-06T13:00:00Z"
      })

      assert {:ok, %{number: 1, labels: ["pipemaestro"]}} =
               Forgejo.get_issue(client(), "acme/app", 1)

      assert {:ok, [%{number: 2}]} =
               Forgejo.list_issues(client(), "acme/app",
                 since: ~U[2026-11-06 12:00:00Z],
                 labels: ["pipemaestro"]
               )

      assert {:ok, issues} = Forgejo.list_issues(client(), "acme/app", page_size: 1)
      assert Enum.map(issues, & &1.number) == [1, 2, 3]
    end

    test "comments, edits, reacts and changes labels", %{fake: fake} do
      FakeForgejo.put_issue(fake, "acme/app", %{"number" => 3, "labels" => ["bug"]})

      :ok =
        Forgejo.ensure_labels(client(), "acme/app", [
          %{name: "bug", color: "d73a4a", description: ""},
          %{name: "pipemaestro:triando", color: "fbca04", description: ""}
        ])

      assert {:ok, id} = Forgejo.create_comment(client(), "acme/app", 3, "Recebida")
      assert Forgejo.update_comment(client(), "acme/app", id, "Triando") == :ok
      assert Forgejo.add_reaction(client(), "acme/app", {:issue, 3}, "eyes") == :ok
      assert Forgejo.add_reaction(client(), "acme/app", {:comment, id}, "+1") == :ok

      assert Forgejo.set_labels(client(), "acme/app", 3,
               add: ["pipemaestro:triando"],
               remove: ["bug"]
             ) == :ok

      repo = FakeForgejo.repo(fake, "acme/app")
      assert [%{"body" => "Triando", "issue" => 3}] = repo.comments
      assert repo.reactions == [{:issue, 3, "eyes"}, {:comment, id, "+1"}]
      assert Enum.map(repo.issues[3]["labels"], & &1["name"]) == ["pipemaestro:triando"]
      assert Forgejo.set_labels(client(), "acme/app", 3, add: [], remove: []) == :ok
    end

    test "creates, changes and removes the webhook", %{fake: fake} do
      assert {:ok, id} =
               Forgejo.create_webhook(client(), "acme/app", "https://pm.test/hook", "s1")

      assert [
               %{
                 "type" => "forgejo",
                 "active" => true,
                 "config" => %{
                   "url" => "https://pm.test/hook",
                   "secret" => "s1",
                   "content_type" => "json"
                 },
                 "events" => events
               }
             ] =
               FakeForgejo.repo(fake, "acme/app").hooks

      assert events == ~w(issues issue_comment pull_request pull_request_review)
      assert Forgejo.update_webhook(client(), "acme/app", id, "https://pm.test/hook", "s2") == :ok
      assert [%{"config" => %{"secret" => "s2"}}] = FakeForgejo.repo(fake, "acme/app").hooks
      assert Forgejo.delete_webhook(client(), "acme/app", id) == :ok
      assert FakeForgejo.repo(fake, "acme/app").hooks == []
    end

    test "posts a commit status", %{fake: fake} do
      status = %{
        state: "pending",
        context: "pipemaestro/a",
        description: "Etapa A",
        target_url: "https://pm.test/t/1"
      }

      assert Forgejo.set_commit_status(client(), "acme/app", "abc123", status) == :ok

      assert [
               %{
                 "sha" => "abc123",
                 "state" => "pending",
                 "context" => "pipemaestro/a",
                 "target_url" => "https://pm.test/t/1"
               }
             ] =
               FakeForgejo.repo(fake, "acme/app").statuses
    end

    test "opens a draft pull request, finds it by branch and marks it ready", %{fake: fake} do
      assert {:ok, nil} = Forgejo.find_open_pr(client(), "acme/app", "cp/x-1")

      assert {:ok, %{number: 1, title: "WIP: Corrige login", url: url}} =
               Forgejo.create_pr(client(), "acme/app", %{
                 head: "cp/x-1",
                 base: "main",
                 title: "Corrige login",
                 body: "corpo",
                 draft: true
               })

      assert url == "https://forge.test/acme/app/pulls/1"

      assert {:ok, %{number: 1, body: "corpo", draft: true} = pr} =
               Forgejo.find_open_pr(client(), "acme/app", "cp/x-1")

      assert {:ok, %{title: "Corrige login", draft: false}} =
               Forgejo.update_pr(client(), "acme/app", pr, %{ready: true, body: "novo"})

      assert [%{"title" => "Corrige login", "body" => "novo"}] =
               FakeForgejo.repo(fake, "acme/app").pulls
    end

    test "answers errors without raising", %{fake: fake} do
      FakeForgejo.fail(fake, {"GET", "/api/v1/user"}, 500)
      assert {:error, %{status: 500, message: "falha simulada"}} = Forgejo.whoami(client())

      unreachable = Forgejo.client("https://forge.test", "token tok")
      Req.Test.stub(PipeMaestro.Integrations, &Req.Test.transport_error(&1, :timeout))
      assert {:error, %{status: nil, message: message}} = Forgejo.whoami(unreachable)
      assert message =~ "timeout"
    end
  end

  test "builds a client of the instance's API" do
    assert %Client{provider: Forgejo, base_url: "https://forge.test"} = client()
  end

  describe "a pull request's commits" do
    setup do
      fake = FakeForgejo.start()

      FakeForgejo.put_pull(fake, "acme/app", %{
        "number" => 7,
        "state" => "closed",
        "merged" => true,
        "merged_at" => "2026-11-05T10:00:00Z",
        "closed_at" => "2026-11-05T10:00:00Z",
        "head" => %{"ref" => "cp/x", "sha" => "c60"},
        "base" => %{"ref" => "main"},
        "html_url" => "https://forge.test/acme/app/pulls/7",
        "commits" =>
          for(n <- 1..60, do: FakeForgejo.commit_json("c#{n}")) ++
            [FakeForgejo.commit_json("m1", ["c60", "main"])]
      })

      %{fake: fake}
    end

    test "every page, oldest first, with each commit's parents and date" do
      assert {:ok, commits} = Forgejo.pr_commits(client(), "acme/app", 7)
      assert length(commits) == 61

      assert hd(commits) == %{
               sha: "c1",
               parents: ["base"],
               committed_at: ~U[2026-11-01 12:00:00Z]
             }

      assert List.last(commits).parents == ["c60", "main"]
    end

    test "a pull request that does not exist is an error" do
      assert {:error, %{status: 404}} = Forgejo.pr_commits(client(), "acme/app", 99)
    end

    test "the pull request says when it was merged" do
      assert {:ok, %{merged: true, merged_at: ~U[2026-11-05 10:00:00Z], closed_at: _}} =
               Forgejo.get_pr(client(), "acme/app", 7)
    end
  end
end
