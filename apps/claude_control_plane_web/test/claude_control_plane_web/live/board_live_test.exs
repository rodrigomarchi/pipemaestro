defmodule ClaudeControlPlaneWeb.BoardLiveTest do
  use ClaudeControlPlaneWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ClaudeControlPlane.{Jobs, Tasks}

  setup :register_and_log_in_member

  defp board_setup(%{workspace: workspace, user: user}) do
    {runner, _token} = runner_fixture(workspace, user, %{name: "mac"})

    runner =
      with_directories(runner, [
        %{"name" => "app", "git" => true},
        %{"name" => "notas", "git" => false}
      ])

    %{runner: runner, pipeline: pipeline_fixture(workspace, %{"name" => "Duas etapas"})}
  end

  defp create_task(ctx, title, attrs \\ %{}) do
    {:ok, task} =
      Tasks.create_task(
        ctx.user,
        ctx.workspace,
        Enum.into(attrs, %{
          "title" => title,
          "prompt" => "faça",
          "pipeline_id" => ctx.pipeline.id,
          "runner_id" => ctx.runner.id,
          "directory" => "app"
        })
      )

    task
  end

  defp finish_current(ctx, task, output) do
    job = List.last(Tasks.get_task!(ctx.workspace, task.id).stage_runs).job
    {:ok, _} = Jobs.mark_started(ctx.runner, job.id)

    {:ok, _} =
      Jobs.finish_job(ctx.runner, job.id, %{
        "status" => "succeeded",
        "exit_code" => 0,
        "cost_usd" => 0.5,
        "structured_output" => output,
        "artifact" => "# ok"
      })
  end

  describe "with tasks" do
    setup :board_setup

    test "groups the tasks by state, live, with the numbers", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}")
      assert has_element?(view, "[data-testid=board-column-running]", "Nenhuma tarefa")

      running = create_task(ctx, "Corrigir login")
      blocked = create_task(ctx, "Tela branca")
      done = create_task(ctx, "Ajustar rodapé")

      assert has_element?(
               view,
               "[data-testid=board-column-running] [data-testid=board-task-#{running.id}]",
               "Corrigir login"
             )

      assert has_element?(view, "[data-testid=board-task-#{running.id}]", "1/2 · Etapa A")
      assert has_element?(view, "[data-testid=board-task-#{running.id}]", "mac:app")

      finish_current(ctx, blocked, %{"status" => "bloqueado", "resumo" => "Qual navegador?"})

      assert has_element?(
               view,
               "[data-testid=board-column-awaiting] [data-testid=board-task-#{blocked.id}]"
             )

      finish_current(ctx, done, %{"status" => "ok", "resumo" => "a"})
      finish_current(ctx, done, %{"status" => "ok", "resumo" => "b"})

      assert has_element?(
               view,
               "[data-testid=board-column-done] [data-testid=board-task-#{done.id}]"
             )

      assert has_element?(view, "[data-testid=board-stat-running]", "1")
      assert has_element?(view, "[data-testid=board-stat-awaiting]", "1")
      assert has_element?(view, "[data-testid=board-stat-succeeded]", "1")
      assert has_element?(view, "[data-testid=board-stat-cost]", "US$ 1.5000")

      assert has_element?(view, "[data-testid=board-decision-#{blocked.id}]", "Qual navegador?")
      assert has_element?(view, "[data-testid=board-activity]", "Ajustar rodapé")
    end

    test "alerts on a task whose runner is offline", ctx do
      task = create_task(ctx, "Parada")
      {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}")
      assert has_element?(view, "[data-testid=board-alert-offline-#{task.id}]", "Parada")
      assert has_element?(view, "[data-testid=board-alert-offline-#{task.id}]", "mac")
    end

    test "filters by pipeline, runner, directory and person", ctx do
      other = pipeline_fixture(ctx.workspace, %{"name" => "Outro"})
      a = create_task(ctx, "Na app")
      b = create_task(ctx, "Nas notas", %{"directory" => "notas", "pipeline_id" => other.id})

      {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}")
      assert has_element?(view, "[data-testid=board-task-#{a.id}]")
      assert has_element?(view, "[data-testid=board-task-#{b.id}]")

      view |> form("#board-filters", filters: %{pipeline: "Outro"}) |> render_change()
      refute has_element?(view, "[data-testid=board-task-#{a.id}]")
      assert has_element?(view, "[data-testid=board-task-#{b.id}]")

      view
      |> form("#board-filters", filters: %{pipeline: "", directory: "app"})
      |> render_change()

      assert has_element?(view, "[data-testid=board-task-#{a.id}]")
      refute has_element?(view, "[data-testid=board-task-#{b.id}]")

      view
      |> form("#board-filters",
        filters: %{directory: "", user_id: ctx.user.id, runner_id: ctx.runner.id}
      )
      |> render_change()

      assert has_element?(view, "[data-testid=board-task-#{a.id}]")
      assert has_element?(view, "[data-testid=board-task-#{b.id}]")
    end
  end

  test "an empty workspace points to the first task", %{conn: conn, workspace: workspace} do
    {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}")
    assert has_element?(view, "[data-testid=board-no-decisions]")

    assert {:error, {:live_redirect, %{to: path}}} =
             view |> element("[data-testid=new-task]") |> render_click()

    assert path == "/w/#{workspace.slug}/tasks"
  end

  test "shows the signed-in user and the workspace", %{conn: conn, workspace: workspace} do
    {:ok, _view, html} = live(conn, ~p"/w/#{workspace.slug}")

    assert html =~ "Ana Lima"
    assert html =~ "Acme Engineering"
  end

  test "a workspace the user does not belong to is refused", %{conn: conn} do
    other = workspace_fixture()

    assert {:error, {:redirect, %{to: "/workspaces", flash: %{"error" => _}}}} =
             live(conn, ~p"/w/#{other.slug}")
  end

  test "an unknown workspace is refused", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/workspaces"}}} = live(conn, ~p"/w/nao-existe")
  end

  test "the switcher lists every workspace of the user", %{
    conn: conn,
    workspace: workspace,
    user: user
  } do
    other = workspace_fixture(%{name: "Globex"})
    {:ok, _} = ClaudeControlPlane.Workspaces.add_member(other, user)

    {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}")

    assert has_element?(view, ~s(#workspace-switcher a[href="/w/#{other.slug}"]))
  end

  test "a revoked session leaves the board", %{conn: conn, workspace: workspace, user: user} do
    {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}")

    ClaudeControlPlaneWeb.UserAuth.disconnect_user(user)

    assert_redirect(view, ~p"/login")
  end

  test "anonymous visitors are sent to sign in", %{workspace: workspace} do
    conn = get(build_conn(), ~p"/w/#{workspace.slug}")
    assert redirected_to(conn) == ~p"/login"
  end

  test "shows the workspace's real runners, live", %{conn: conn, workspace: workspace, user: user} do
    {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}")
    assert has_element?(view, "[data-testid=board-no-runners]")

    {_runner, _token} = runner_fixture(workspace, user, %{name: "build-01"})
    ClaudeControlPlaneWeb.RunnerStatus.notify_changed(workspace.id)

    assert render(view) =~ "build-01"
    assert has_element?(view, "[data-testid=board-runner-status-build-01]", "Offline")
  end
end
