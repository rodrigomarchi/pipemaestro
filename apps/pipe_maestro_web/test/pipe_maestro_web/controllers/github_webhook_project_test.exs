defmodule PipeMaestroWeb.GithubWebhookProjectTest do
  use PipeMaestroWeb.ConnCase, async: true

  alias PipeMaestro.{Jobs, Projects, Proposals, Repo, Runners, Secrets, Tasks}

  @secret "segredo-do-webhook"

  setup do
    workspace = workspace_fixture()
    admin = member_fixture(workspace)
    {runner, _token} = runner_fixture(workspace, admin, %{name: "mac"})

    {:ok, runner} =
      Runners.record_hello(
        runner,
        hello_fixture(%{
          directories: [%{"name" => "app", "git" => true}],
          capabilities: ["scratch"]
        })
      )

    pipeline = pipeline_fixture(workspace)
    {:ok, _} = Secrets.put(workspace, "GITHUB_WEBHOOK_SECRET", @secret)

    {:ok, project} =
      Projects.create_project(
        workspace,
        %{
          "name" => "App",
          "runner_id" => runner.id,
          "directory" => "app",
          "github_repo" => "acme/app",
          "trigger_label" => "claude",
          "trigger_pipeline_id" => pipeline.id
        },
        admin
      )

    %{workspace: workspace, runner: runner, project: project}
  end

  defp labeled(number \\ 9) do
    %{
      "action" => "labeled",
      "label" => %{"name" => "claude"},
      "repository" => %{"full_name" => "acme/app"},
      "issue" => %{
        "title" => "Botão quebrado",
        "body" => "Nada acontece.",
        "html_url" => "https://github.com/acme/app/issues/#{number}"
      }
    }
  end

  defp deliver(conn, workspace, payload) do
    body = JSON.encode!(payload)

    signature =
      "sha256=" <> Base.encode16(:crypto.mac(:hmac, :sha256, @secret, body), case: :lower)

    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-github-event", "issues")
    |> put_req_header("x-hub-signature-256", signature)
    |> post(~p"/api/github/webhook/#{workspace.slug}", body)
  end

  test "the task goes to the project's runner, and waits for it when offline", ctx do
    conn = deliver(ctx.conn, ctx.workspace, labeled())
    assert %{"task_id" => task_id} = json_response(conn, 201)

    task = Tasks.get_task!(ctx.workspace, task_id)
    assert task.project_id == ctx.project.id
    assert task.runner_id == ctx.runner.id

    [stage_run | _] = task.stage_runs
    assert Enum.map(Jobs.queued_for_runner(ctx.runner), & &1.id) == [stage_run.job.id]
  end

  test "triage goes to the project's runner, even offline", ctx do
    {:ok, _project} = Projects.update_project(ctx.project, %{"trigger_mode" => "triage"})

    conn = deliver(ctx.conn, ctx.workspace, labeled())
    assert %{"proposal_id" => id} = json_response(conn, 201)

    job = Proposals.get_proposal!(ctx.workspace, id)
    assert job.runner_id == ctx.runner.id
    assert job.project_id == ctx.project.id
  end

  test "a project without a runner refuses the issue, saying so", ctx do
    Repo.delete!(ctx.runner)

    conn = deliver(ctx.conn, ctx.workspace, labeled())
    assert %{"error" => "o projeto precisa de um runner"} = json_response(conn, 422)
    assert Tasks.list_tasks(ctx.workspace) == []
  end

  test "a triaging project without a runner refuses the issue, saying so", ctx do
    {:ok, _project} = Projects.update_project(ctx.project, %{"trigger_mode" => "triage"})
    Repo.delete!(ctx.runner)

    conn = deliver(ctx.conn, ctx.workspace, labeled())
    assert %{"error" => "o projeto precisa de um runner"} = json_response(conn, 422)
  end
end
