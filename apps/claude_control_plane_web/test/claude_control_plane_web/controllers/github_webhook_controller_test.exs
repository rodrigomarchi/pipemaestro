defmodule ClaudeControlPlaneWeb.GithubWebhookControllerTest do
  use ClaudeControlPlaneWeb.ConnCase, async: false

  alias ClaudeControlPlane.{Projects, Secrets, Tasks}
  alias ClaudeControlPlaneWeb.RunnerStatus

  @secret "segredo-do-webhook"

  setup do
    workspace = workspace_fixture()
    admin = member_fixture(workspace)
    {runner, _token} = runner_fixture(workspace, admin, %{name: "mac"})
    runner = with_directories(runner, [%{"name" => "app", "git" => true}])
    pipeline = pipeline_fixture(workspace)
    {:ok, _} = Secrets.put(workspace, "GITHUB_WEBHOOK_SECRET", @secret)

    {:ok, _project} =
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

    %{workspace: workspace, runner: runner}
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
