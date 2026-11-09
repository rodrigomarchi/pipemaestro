defmodule PipeMaestro.Integrations.IssueSourceTest do
  use PipeMaestro.DataCase, async: true

  import PipeMaestro.Fixtures

  alias PipeMaestro.{FakeForgejo, Integrations, Runners, TaskSources}
  alias PipeMaestro.Integrations.IssueSource
  alias PipeMaestro.Tasks.Task
  alias PipeMaestro.TaskSources.{Item, Origin, Source}

  @url "https://github.com/acme/app/issues/42"

  setup do
    workspace = workspace_fixture()
    user = member_fixture(workspace)
    fake = FakeForgejo.start(permissions: %{"ana" => "write"})

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
      project: project,
      repo: repo,
      pipeline: pipeline_fixture(workspace)
    }
  end

  defp issue_origin(ctx) do
    url = "#{FakeForgejo.base_url()}/acme/app/issues/3"

    struct!(Origin,
      source: "git_issue",
      external_id: url,
      url: url,
      ref: %{"number" => 3},
      linked_repo_id: ctx.repo.id
    )
  end

  test "implements the task source behaviour" do
    behaviours = IssueSource.module_info(:attributes) |> Keyword.get_values(:behaviour)
    assert Source in List.flatten(behaviours)
  end

  describe "parse_link/1" do
    test "takes the link of an issue on any git host, as a task made by hand" do
      assert {:ok, origin} = IssueSource.parse_link(@url)
      assert origin.__struct__ == Origin

      assert %{source: "git_issue", external_id: @url, url: @url, ref: %{}, linked_repo_id: nil} =
               origin
    end

    test "refuses a link that is not an issue's, with the message of the screen" do
      assert IssueSource.parse_link("https://github.com/acme/app/pull/42") ==
               {:error, "use o link de uma issue (https://host/dono/repo/issues/N)"}
    end

    test "is how the platform reads a link pasted on a task" do
      assert {:ok, %{source: "git_issue"}} = TaskSources.parse_link(@url)
      assert {:error, _message} = TaskSources.parse_link("https://example.com/x")
    end
  end

  test "fetch_item/1 reads the issue again and normalizes it", ctx do
    origin = issue_origin(ctx)
    assert {:ok, item} = IssueSource.fetch_item(origin)
    assert item.__struct__ == Item

    assert %{
             source: "git_issue",
             external_id: external_id,
             url: url,
             title: "Login quebra",
             description: "Com e-mail maiúsculo.",
             author: "ana",
             labels: labels,
             kind: "Issue",
             ref: %{"number" => 3}
           } = item

    assert {external_id, url} == {origin.url, origin.url}
    assert Enum.sort(labels) == ["bug", "pipemaestro"]
    assert item.linked_repo_id == ctx.repo.id
  end

  test "a task from a linked issue keeps the repository of the git host and the number", ctx do
    {:ok, item} = IssueSource.fetch_item(issue_origin(ctx))

    {:ok, task} =
      TaskSources.start(ctx.workspace, item, %{
        mode: "task",
        project_id: ctx.repo.project_id,
        pipeline_id: ctx.pipeline.id,
        acting_user_id: ctx.user.id,
        auto_approve: true
      })

    assert %{
             source: "git_issue",
             source_id: source_id,
             source_url: source_url,
             source_ref: %{"number" => 3},
             linked_repo_id: repo_id,
             title: "Login quebra"
           } = task

    assert {source_id, source_url, repo_id} == {item.url, item.url, ctx.repo.id}
    assert task.prompt == "Com e-mail maiúsculo.\n\nIssue: #{item.url}"
  end

  describe "what the issue gets with the delivery" do
    test "the pull request closes the issue" do
      task = struct!(Task, source: "git_issue", source_id: @url, source_url: @url)
      assert IssueSource.pr_reference(task) == "Closes #{@url}"
    end

    test "the runner comments the decision's note on the issue" do
      task =
        struct!(Task,
          source: "git_issue",
          source_id: @url,
          source_url: @url,
          pending_source_note: "**Decisão na etapa \"A\"**: refazer a etapa."
        )

      assert IssueSource.runner_delivery(task) == %{
               "issue_comment" => %{
                 "url" => @url,
                 "body" => "**Decisão na etapa \"A\"**: refazer a etapa."
               }
             }

      assert IssueSource.runner_delivery(%{task | pending_source_note: nil}) == %{}
    end

    test "a task made by hand, without a linked repository, reflects nothing on the host" do
      task = struct!(Task, source: "git_issue", source_id: @url, source_url: @url)
      assert IssueSource.task_changed(task) == :ok
    end
  end
end
