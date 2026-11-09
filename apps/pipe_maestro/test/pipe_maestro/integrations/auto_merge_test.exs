defmodule PipeMaestro.Integrations.AutoMergeTest do
  use PipeMaestro.DataCase, async: true

  import PipeMaestro.Fixtures

  alias PipeMaestro.{FakeForgejo, Integrations, Repo, Runners, Tasks}
  alias PipeMaestro.Integrations.{AutoMerge, Feedback}
  alias PipeMaestro.Notifications.Notification
  alias PipeMaestro.Tasks.Task
  alias PipeMaestro.TaskSources.Origin

  @sha "abc123"

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
    project = project_fixture(runner, "app")

    {:ok, repo} =
      Integrations.link_repo(
        connection,
        user,
        %{"full_name" => "acme/app", "project_id" => project.id},
        "https://pm.test/hook"
      )

    pipeline =
      pipeline_fixture(workspace, %{
        "name" => "Com merge",
        "delivery" => "pr",
        "auto_merge" => "true",
        "max_merge_fixes" => "2"
      })

    {:ok, task} =
      Tasks.create_task(
        user,
        workspace,
        %{
          "title" => "Corrige login",
          "prompt" => "O login quebra.",
          "pipeline_id" => pipeline.id,
          "project_id" => project.id
        },
        origin: %Origin{
          source: "git_issue",
          external_id: "https://forge.test/acme/app/issues/3",
          url: "https://forge.test/acme/app/issues/3",
          ref: %{"number" => 3},
          linked_repo_id: repo.id
        }
      )

    %{fake: fake, task: task, user: user}
  end

  # The task succeeded and the feedback opened its pull request, ready, at
  # the task's last commit.
  defp waiting(ctx, changes \\ []) do
    task =
      ctx.task
      |> Ecto.Changeset.change(
        Keyword.merge(
          [
            status: :succeeded,
            head_sha: @sha,
            merge_state: "waiting_checks",
            merge_waiting_since: DateTime.utc_now(:second)
          ],
          changes
        )
      )
      |> Repo.update!()

    :ok = Feedback.sync(task.id)
    edit_pull(ctx, &put_in(&1, ["head", "sha"], @sha))
    Repo.reload!(task)
  end

  defp edit_pull(ctx, fun), do: FakeForgejo.edit_pull(ctx.fake, "acme/app", 1, fun)
  defp pull(ctx), do: hd(FakeForgejo.repo(ctx.fake, "acme/app").pulls)

  defp status(ctx, context, state),
    do: FakeForgejo.put_status(ctx.fake, "acme/app", @sha, context, state)

  defp notified?(task, kind),
    do: Enum.any?(Repo.all(Notification), &(&1.kind == kind and &1.task_id == task.id))

  test "with no check of the repository's own, it merges with the pipeline's method", ctx do
    task = waiting(ctx)

    # The feedback set the platform's own statuses on the commit: they do not count.
    assert Enum.any?(FakeForgejo.repo(ctx.fake, "acme/app").statuses, &(&1["sha"] == @sha))

    assert AutoMerge.check(task.id) == :merged

    assert %{"merged" => true, "merge" => %{"Do" => "squash", "head_commit_id" => @sha}} =
             pull(ctx)

    task = Repo.reload!(task)
    assert %Task{merge_state: "merged", issue_feedback: %{"merged" => true}} = task
    assert notified?(task, :task_merged)
    assert AutoMerge.check(task.id) == :skipped
  end

  test "waits for a check still running, then merges once it passed", ctx do
    task = waiting(ctx)
    status(ctx, "ci/test", "pending")

    assert AutoMerge.waiting_task_ids() == [task.id]
    assert AutoMerge.check(task.id) == :waiting
    refute pull(ctx)["merged"]

    status(ctx, "ci/test", "success")
    assert AutoMerge.check(task.id) == :merged
  end

  test "waits while the pull request is a draft or behind the task's last commit", ctx do
    task = waiting(ctx)
    edit_pull(ctx, &%{&1 | "title" => "WIP: " <> &1["title"]})
    assert AutoMerge.check(task.id) == :waiting

    edit_pull(ctx, &%{put_in(&1, ["head", "sha"], "older") | "title" => "Corrige login"})
    assert AutoMerge.check(task.id) == :waiting
    refute pull(ctx)["merged"]
  end

  test "a check that failed sends the task to a correction with what failed", ctx do
    task = waiting(ctx)
    status(ctx, "ci/test", "failure")

    assert AutoMerge.check(task.id) == :fixing

    task = Repo.reload!(task)
    assert %Task{status: :running, merge_state: "fixing", merge_fixes: 1} = task
    assert List.last(task.stages).name == "Correção 1"

    assert [%{action: :correct, instructions: prompt, decided_via: "merge automático"}] =
             Tasks.list_decisions(task)

    assert prompt =~ "`ci/test`"
    assert prompt =~ "https://forge.test/acme/app/actions/runs/1"
    refute pull(ctx)["merged"]
  end

  test "a conflict seen twice at the same head sends the task to a correction", ctx do
    task = waiting(ctx)
    edit_pull(ctx, &Map.put(&1, "mergeable", false))

    assert AutoMerge.check(task.id) == :waiting
    assert AutoMerge.check(task.id) == :fixing

    assert [%{instructions: prompt}] = Tasks.list_decisions(task)
    assert prompt =~ "git merge origin/main"
  end

  test "past the corrections allowed, the merge is blocked and the people told", ctx do
    task = waiting(ctx, merge_fixes: 2)
    status(ctx, "ci/test", "error")

    assert AutoMerge.check(task.id) == :blocked

    task = Repo.reload!(task)
    assert %Task{status: :succeeded, merge_state: "blocked", merge_reason: reason} = task
    assert reason =~ "`ci/test`"
    assert reason =~ "2 correções"
    assert notified?(task, :task_merge_blocked)
  end

  test "a merge the host refuses is blocked without a correction", ctx do
    task = waiting(ctx)
    FakeForgejo.fail(ctx.fake, {"POST", "/api/v1/repos/acme/app/pulls/1/merge"}, 405)

    assert AutoMerge.check(task.id) == :blocked

    assert %Task{merge_state: "blocked", merge_reason: "o host recusou o merge" <> _} =
             Repo.reload!(task)

    assert Tasks.list_decisions(task) == []
  end

  test "checks that do not end in time block the merge", ctx do
    task = waiting(ctx, merge_waiting_since: DateTime.add(DateTime.utc_now(:second), -7, :hour))
    assert AutoMerge.check(task.id) == :blocked
    assert Repo.reload!(task).merge_reason =~ "não terminaram"
  end

  test "a pull request a person merged ends the wait", ctx do
    task = waiting(ctx)
    edit_pull(ctx, &Map.merge(&1, %{"merged" => true, "state" => "closed"}))
    assert AutoMerge.check(task.id) == :merged
    refute Map.has_key?(pull(ctx), "merge")
  end

  test "a pull request closed without the merge blocks it", ctx do
    task = waiting(ctx)
    edit_pull(ctx, &Map.put(&1, "state", "closed"))
    assert AutoMerge.check(task.id) == :blocked
    assert Repo.reload!(task).merge_reason =~ "fechado"
  end

  test "a host that cannot be reached leaves the task waiting", ctx do
    task = waiting(ctx)
    FakeForgejo.fail(ctx.fake, {"GET", "/api/v1/repos/acme/app/pulls/1"}, 500)

    assert {:error, "HTTP 500" <> _} = AutoMerge.check(task.id)
    assert Repo.reload!(task).merge_state == "waiting_checks"
  end

  test "a task not waiting for its merge is left alone", ctx do
    assert AutoMerge.check(ctx.task.id) == :skipped
  end
end
