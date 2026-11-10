defmodule PipeMaestro.Integrations.PrOutcomesTest do
  use PipeMaestro.DataCase, async: true

  import PipeMaestro.Fixtures

  alias PipeMaestro.{FakeForgejo, FakeGitHub, Integrations, Jobs, Repo, Runners, Tasks}
  alias PipeMaestro.Integrations.{Connection, Conversation, Event, PrOutcome, PrOutcomes}
  alias PipeMaestro.Tasks.Task

  @commits_path "/api/v1/repos/acme/app/pulls/7/commits"

  defp commit(sha, parents \\ ["base"]), do: FakeForgejo.commit_json(sha, parents)

  # A task of `acme/app` on `connection`, created by `user` in a runner of
  # its own; answers the task and the runner.
  defp linked_task(workspace, user, connection, issue_url) do
    {runner, _token} = runner_fixture(workspace, user, %{name: "mac"})

    {:ok, runner} =
      Runners.record_hello(
        runner,
        hello_fixture(%{directories: [%{"name" => "app", "git" => true}]})
      )

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
          "pipeline_id" => pipeline_fixture(workspace, %{"delivery" => "pr"}).id,
          "project_id" => project.id,
          "issue_url" => issue_url
        },
        issue: %{linked_repo_id: repo.id, issue_number: 3}
      )

    %{task: task, runner: runner, repo: repo}
  end

  # The task ended with its pull request 7 open at `head`, the pipeline's
  # last commit.
  defp delivered(task, head, attrs \\ []) do
    task
    |> Ecto.Changeset.change(
      Keyword.merge(
        [
          status: :succeeded,
          head_sha: head,
          pr_url: "https://forge.test/acme/app/pulls/7",
          issue_feedback: %{"pr_number" => 7},
          finished_at: DateTime.add(DateTime.utc_now(:second), -3_600)
        ],
        attrs
      )
    )
    |> Repo.update!()
  end

  defp set_commits(fake, commits),
    do: FakeForgejo.edit_pull(fake, "acme/app", 7, &Map.put(&1, "commits", commits))

  describe "on Forgejo" do
    setup do
      workspace = workspace_fixture()
      user = member_fixture(workspace)
      fake = FakeForgejo.start(permissions: %{"bia" => "write"})
      FakeForgejo.put_issue(fake, "acme/app", %{"number" => 3, "labels" => ["pipemaestro"]})
      connection = connection_fixture(workspace)

      linked =
        linked_task(workspace, user, connection, "https://forge.test/acme/app/issues/3")

      FakeForgejo.put_pull(fake, "acme/app", %{
        "number" => 7,
        "state" => "open",
        "head" => %{"ref" => linked.task.branch, "sha" => "p1"},
        "base" => %{"ref" => "main"},
        "html_url" => "https://forge.test/acme/app/pulls/7",
        "commits" => [commit("p1")]
      })

      Map.merge(linked, %{workspace: workspace, user: user, fake: fake, connection: connection})
    end

    test "the first success with a pull request makes it ready, once", ctx do
      assert PrOutcomes.ready(ctx.task) == nil
      assert PrOutcomes.get(ctx.task.id) == nil

      task = delivered(ctx.task, "p1")

      assert %{state: "open", pr_number: 7, review_rounds: 0, commits_tracked: true} =
               PrOutcomes.ready(task)

      assert PrOutcomes.get(task.id).ready_at == task.finished_at

      # A correction ends the task again later: it was ready the first time.
      later = delivered(task, "p2", finished_at: DateTime.utc_now(:second))
      PrOutcomes.ready(later)
      assert PrOutcomes.get(task.id).ready_at == task.finished_at
      assert Repo.aggregate(PrOutcome, :count) == 1
    end

    test "the pipeline finishing with its pull request makes it ready", ctx do
      task = run_to_the_end(ctx, ctx.task)

      assert %Task{status: :succeeded, pr_url: "https://forge.test/acme/app/pulls/7"} = task
      assert %{state: "open", ready_at: ready_at} = PrOutcomes.get(task.id)
      assert ready_at == task.finished_at
    end

    test "a connection the platform does not call keeps no commits", ctx do
      ctx.connection |> Ecto.Changeset.change(api_mode: "runner") |> Repo.update!()
      task = delivered(ctx.task, "p1")

      assert %{commits_tracked: false} = PrOutcomes.ready(task)
    end

    test "commits up to the pipeline's head are its own; any other is a person's", ctx do
      task = delivered(ctx.task, "p2")
      PrOutcomes.ready(task)

      # The pipeline's delivery pushed p1 and p2.
      set_commits(ctx.fake, [commit("p1"), commit("p2")])
      assert :ok = PrOutcomes.observe(task.id)

      assert %{pipeline_shas: ["p1", "p2"], human_shas: [], observed_head: "p2"} =
               PrOutcomes.get(task.id)

      # A person pushes h1 to the branch while the task is stopped.
      set_commits(ctx.fake, [commit("p1"), commit("p2"), commit("h1")])
      assert :ok = PrOutcomes.observe(task.id)
      assert PrOutcomes.get(task.id).human_shas == ["h1"]

      # Reading the commits again changes nothing.
      assert :ok = PrOutcomes.observe(task.id)
      assert %{human_shas: ["h1"], pipeline_shas: ["p1", "p2"]} = PrOutcomes.get(task.id)

      # A correction pushes p3; h2 comes after it, from a person; m1 brings
      # the base into the branch (two parents) and is nobody's change.
      task = delivered(task, "p3")

      set_commits(ctx.fake, [
        commit("p1"),
        commit("p2"),
        commit("h1"),
        commit("p3"),
        commit("m1", ["p3", "main"]),
        commit("h2")
      ])

      assert :ok = PrOutcomes.observe(task.id)

      assert %{
               pipeline_shas: ["p1", "p2", "p3"],
               human_shas: ["h1", "h2"],
               observed_head: "p3"
             } = PrOutcomes.get(task.id)
    end

    test "every page of the pull request's commits is read", ctx do
      shas = for n <- 1..75, do: "p#{n}"
      task = delivered(ctx.task, "p75")
      PrOutcomes.ready(task)
      set_commits(ctx.fake, Enum.map(shas, &commit/1))

      assert :ok = PrOutcomes.observe(task.id)
      assert PrOutcomes.get(task.id).pipeline_shas == shas
    end

    test "a failure of the host is kept to try again, and stops nothing", ctx do
      task = delivered(ctx.task, "p1")
      PrOutcomes.ready(task)
      FakeForgejo.fail(ctx.fake, {"GET", @commits_path}, 500, 1)

      assert {:error, message} = PrOutcomes.observe(task.id)
      assert is_binary(message)
      assert %{commits_error: error, pipeline_shas: []} = PrOutcomes.get(task.id)
      assert is_binary(error)
      assert Repo.reload!(task).status == :succeeded

      assert :ok = PrOutcomes.observe(task.id)
      assert %{commits_error: nil, pipeline_shas: ["p1"]} = PrOutcomes.get(task.id)
    end

    test "a task without an outcome is not observed", ctx do
      assert PrOutcomes.observe(ctx.task.id) == :skipped
    end
  end

  describe "on GitHub" do
    setup do
      fake = FakeGitHub.start(permissions: %{"bia" => "write"})
      FakeGitHub.put_issue(fake, "acme/app", %{"number" => 3})
      workspace = workspace_fixture()
      user = member_fixture(workspace)

      {:ok, connection} =
        Integrations.create_connection(workspace, member_fixture(workspace), %{
          "name" => "GitHub",
          "provider" => "github",
          "auth_kind" => "github_app"
        })

      connection =
        connection
        |> Connection.installation_changeset("99")
        |> Ecto.Changeset.change(status: "active")
        |> Repo.update!()

      linked = linked_task(workspace, user, connection, "https://github.test/acme/app/issues/3")

      FakeGitHub.put_pull(fake, "acme/app", %{
        "number" => 7,
        "node_id" => "PR_7",
        "state" => "open",
        "draft" => false,
        "head" => %{"ref" => linked.task.branch, "sha" => "p1"},
        "base" => %{"ref" => "main"},
        "html_url" => "https://github.test/acme/app/pull/7",
        "commits" => [commit("p1")]
      })

      Map.merge(linked, %{fake: fake, connection: connection})
    end

    defp merged_event(task) do
      %Event{
        kind: :pr_closed,
        external_id: "gh-#{System.unique_integer([:positive])}",
        repo: "acme/app",
        pr: %{
          number: 7,
          merged: true,
          head: task.branch,
          merged_at: ~U[2026-11-05 10:00:00Z],
          closed_at: ~U[2026-11-05 10:00:00Z]
        },
        sender: "bia"
      }
    end

    test "a commit the pipeline did not push makes the merged PR accepted with changes", ctx do
      task =
        delivered(ctx.task, "p1", pr_url: "https://github.test/acme/app/pull/7")

      PrOutcomes.ready(task)
      assert :ok = PrOutcomes.observe(task.id)

      FakeGitHub.edit_pull(
        ctx.fake,
        "acme/app",
        7,
        &Map.put(&1, "commits", [commit("p1"), commit("h1")])
      )

      assert {:processed, "pull request integrado", _} =
               Conversation.handle(ctx.connection, ctx.repo, merged_event(task))

      outcome = PrOutcomes.get(task.id)

      assert %{
               state: "merged",
               merged_at: ~U[2026-11-05 10:00:00Z],
               human_shas: ["h1"],
               commits_final: true
             } = outcome

      assert PrOutcome.classify(outcome) == :accepted_changed
    end

    test "a PR merged as the pipeline left it is accepted without changes", ctx do
      task = delivered(ctx.task, "p1", pr_url: "https://github.test/acme/app/pull/7")
      PrOutcomes.ready(task)
      :ok = PrOutcomes.observe(task.id)

      Conversation.handle(ctx.connection, ctx.repo, merged_event(task))

      assert PrOutcome.classify(PrOutcomes.get(task.id)) == :accepted_clean
    end
  end

  describe "classify/1" do
    test "merged, closed or open, with or without changes" do
      merged = %PrOutcome{state: "merged", human_shas: [], review_rounds: 0}

      assert PrOutcome.classify(merged) == :accepted_clean
      assert PrOutcome.classify(%{merged | human_shas: ["h1"]}) == :accepted_changed
      assert PrOutcome.classify(%{merged | review_rounds: 1}) == :accepted_changed
      assert PrOutcome.classify(%PrOutcome{state: "closed", human_shas: ["h1"]}) == :closed
      assert PrOutcome.classify(%PrOutcome{state: "open"}) == :open
    end
  end

  # Plays the runner through every stage, each pushing a commit to PR 7.
  defp run_to_the_end(ctx, task) do
    task = Tasks.get_task!(ctx.workspace, task.id)

    case Enum.find(task.stage_runs, &(&1.status == :running)) do
      nil ->
        task

      run ->
        {:ok, _} = Jobs.mark_started(ctx.runner, run.job.id)

        {:ok, _} =
          Jobs.finish_job(ctx.runner, run.job.id, %{
            "status" => "succeeded",
            "exit_code" => 0,
            "structured_output" => %{"status" => "ok", "resumo" => "feito"},
            "artifact" => "# Artefato",
            "delivery" => %{
              "commit" => "c#{run.index}",
              "pushed" => true,
              "pr_url" => "https://forge.test/acme/app/pulls/7"
            }
          })

        run_to_the_end(ctx, task)
    end
  end
end
