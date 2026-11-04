defmodule PipeMaestroWeb.GithubWebhookControllerTest do
  use PipeMaestroWeb.ConnCase, async: false

  alias PipeMaestro.{Projects, Proposals, Runners, Secrets, Tasks}
  alias PipeMaestroWeb.RunnerStatus

  @secret "segredo-do-webhook"

  setup do
    workspace = workspace_fixture()
    admin = member_fixture(workspace)
    {runner, _token} = runner_fixture(workspace, admin, %{name: "mac"})
    runner = with_directories(runner, [%{"name" => "app", "git" => true}])
    pipeline = pipeline_fixture(workspace)
    {:ok, _} = Secrets.put(workspace, "GITHUB_WEBHOOK_SECRET", @secret)

    {:ok, project} =
      Projects.create_project(
        workspace,
        %{
          "name" => "App",
          "directory" => "app",
          "github_repo" => "acme/app",
          "trigger_label" => "claude",
          "trigger_pipeline_id" => pipeline.id
        },
        admin
      )

    %{workspace: workspace, runner: runner, project: project, pipeline: pipeline}
  end

  defp bring_online(runner) do
    test_pid = self()

    spawn_link(fn ->
      {:ok, _ref} = RunnerStatus.track(self(), runner)
      send(test_pid, :tracked)
      Process.sleep(:infinity)
    end)

    assert_receive :tracked
  end

  defp labeled(label, number \\ 9) do
    %{
      "action" => "labeled",
      "label" => %{"name" => label},
      "repository" => %{"full_name" => "Acme/App"},
      "issue" => %{
        "title" => "Botão quebrado",
        "body" => "Nada acontece.",
        "html_url" => "https://github.com/acme/app/issues/#{number}"
      }
    }
  end

  defp deliver(conn, workspace, payload, opts \\ []) do
    body = JSON.encode!(payload)
    secret = Keyword.get(opts, :secret, @secret)

    signature =
      "sha256=" <> Base.encode16(:crypto.mac(:hmac, :sha256, secret, body), case: :lower)

    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-github-event", Keyword.get(opts, :event, "issues"))
    |> put_req_header("x-hub-signature-256", signature)
    |> post(~p"/api/github/webhook/#{workspace.slug}", body)
  end

  test "the trigger label on an issue starts a task on an online runner, once", ctx do
    bring_online(ctx.runner)

    conn = deliver(ctx.conn, ctx.workspace, labeled("claude"))
    assert %{"task_id" => task_id} = json_response(conn, 201)
    task = Tasks.get_task!(ctx.workspace, task_id)
    assert task.title == "Botão quebrado"
    assert task.runner_id == ctx.runner.id

    # The same issue again while its task runs: nothing new.
    conn = deliver(build_conn(), ctx.workspace, labeled("claude"))
    assert %{"ignored" => _} = json_response(conn, 200)
  end

  test "a triaging trigger has the agent write the task first, on an updated runner", ctx do
    {:ok, _project} = Projects.update_project(ctx.project, %{"trigger_mode" => "triage"})
    bring_online(ctx.runner)

    # A runner that cannot study a directory cannot triage.
    conn = deliver(ctx.conn, ctx.workspace, labeled("claude"))
    assert %{"error" => "nenhum runner online e atualizado" <> _} = json_response(conn, 422)

    {:ok, runner} =
      Runners.record_hello(
        ctx.runner,
        hello_fixture(%{
          directories: [%{"name" => "app", "git" => true}],
          capabilities: ["scratch"]
        })
      )

    bring_online(runner)
    conn = deliver(build_conn(), ctx.workspace, labeled("claude"))
    assert %{"proposal_id" => id} = json_response(conn, 201)
    assert Tasks.list_tasks(ctx.workspace) == []

    job = Proposals.get_proposal!(ctx.workspace, id)
    assert Proposals.kind(job) == "task"
    assert Proposals.input(job)["issue_url"] == "https://github.com/acme/app/issues/9"
    assert job.prompt =~ "Botão quebrado"
    assert job.prompt =~ "prefira-o"
    assert job.context["scratch"] == true

    # The same issue again while it is triaged: nothing new.
    conn = deliver(build_conn(), ctx.workspace, labeled("claude"))
    assert %{"ignored" => _} = json_response(conn, 200)
  end

  test "ignores other labels, events and repositories", ctx do
    bring_online(ctx.runner)

    assert %{"ignored" => _} =
             deliver(ctx.conn, ctx.workspace, labeled("bug")) |> json_response(200)

    assert %{"ignored" => _} =
             deliver(build_conn(), ctx.workspace, labeled("claude"), event: "push")
             |> json_response(200)

    other_repo = put_in(labeled("claude"), ["repository", "full_name"], "outro/repo")

    assert %{"ignored" => _} =
             deliver(build_conn(), ctx.workspace, other_repo) |> json_response(200)

    assert %{"pong" => true} =
             deliver(build_conn(), ctx.workspace, %{}, event: "ping") |> json_response(200)
  end

  test "refuses a bad signature and says when no runner can take it", ctx do
    assert deliver(ctx.conn, ctx.workspace, labeled("claude"), secret: "outro").status == 401

    assert %{"error" => error} =
             deliver(build_conn(), ctx.workspace, labeled("claude")) |> json_response(422)

    assert error =~ "runner online"
    assert deliver(build_conn(), workspace_fixture(), labeled("claude")).status == 404
  end
end
