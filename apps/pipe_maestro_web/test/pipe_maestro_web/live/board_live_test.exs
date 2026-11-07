defmodule PipeMaestroWeb.BoardLiveTest do
  use PipeMaestroWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias PipeMaestro.{Jobs, Runners, Tasks}
  alias PipeMaestroWeb.RunnerStatus

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

  # `"directory"` names the project of the runner's directory.
  defp create_task(ctx, title, attrs \\ %{}) do
    {directory, attrs} = Map.pop(attrs, "directory", "app")

    {:ok, task} =
      Tasks.create_task(
        ctx.user,
        ctx.workspace,
        Enum.into(attrs, %{
          "title" => title,
          "prompt" => "faça",
          "pipeline_id" => ctx.pipeline.id,
          "project_id" => project_on(ctx.runner, directory).id
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

    test "the tasks tab groups the tasks by state, live", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}?aba=tarefas")
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

      assert has_element?(
               view,
               "[data-testid=board-task-#{running.id}] [data-testid=board-card-project]",
               "app"
             )

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

      refute has_element?(view, "[data-testid=board-stat-running]")
      refute has_element?(view, "[data-testid=board-runners]")
      refute has_element?(view, "[data-testid=board-decision-#{blocked.id}]")
      refute has_element?(view, "[data-testid=board-activity]")
    end

    test "the overview shows the numbers, the next decisions and the latest activity", ctx do
      running = create_task(ctx, "Corrigir login")
      blocked = create_task(ctx, "Tela branca")
      done = create_task(ctx, "Ajustar rodapé")
      finish_current(ctx, blocked, %{"status" => "bloqueado", "resumo" => "Qual navegador?"})
      finish_current(ctx, done, %{"status" => "ok", "resumo" => "a"})
      finish_current(ctx, done, %{"status" => "ok", "resumo" => "b"})

      {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}")

      assert has_element?(view, "[data-testid=board-stat-running]", "1")
      assert has_element?(view, "[data-testid=board-stat-awaiting]", "1")
      assert has_element?(view, "[data-testid=board-stat-succeeded]", "1")
      assert has_element?(view, "[data-testid=board-stat-cost]", "US$ 1.5000")

      assert has_element?(
               view,
               "[data-testid=board-overview-decision-#{blocked.id}]",
               "Qual navegador?"
             )

      assert has_element?(view, "[data-testid=board-overview-activity]", "Ajustar rodapé")
      assert has_element?(view, "[data-testid=board-overview-decisions-all]")
      assert has_element?(view, "[data-testid=board-overview-activity-all]")

      refute has_element?(view, "[data-testid^=board-column-]")
      refute has_element?(view, "[data-testid=board-task-#{running.id}]")
      refute has_element?(view, "#board-filters")
      refute has_element?(view, "[data-testid=board-runners]")
      refute has_element?(view, "[data-testid=board-runner-mac]")
      refute has_element?(view, "[data-testid=board-decision-#{blocked.id}]")
      refute has_element?(view, "[data-testid=board-activity]")
    end

    test "the overview shows only the next three decisions", ctx do
      blocked =
        for title <- ~w(Um Dois Tres Quatro) do
          task = create_task(ctx, title)
          finish_current(ctx, task, %{"status" => "bloqueado", "resumo" => "Ajuda"})
          task
        end

      {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}")

      shown =
        Enum.count(blocked, &has_element?(view, "[data-testid=board-overview-decision-#{&1.id}]"))

      assert shown == 3
      assert has_element?(view, "[data-testid=board-overview-decisions]")
    end

    test "the decisions tab lists every decision waiting", ctx do
      blocked =
        for title <- ~w(Um Dois Tres Quatro) do
          task = create_task(ctx, title)
          finish_current(ctx, task, %{"status" => "bloqueado", "resumo" => "Ajuda #{title}"})
          task
        end

      {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}?aba=decisoes")

      for task <- blocked do
        assert has_element?(
                 view,
                 "[data-testid=board-decision-#{task.id}]",
                 "Ajuda #{task.title}"
               )
      end

      assert has_element?(view, "[data-testid=board-decisions-link]")
      refute has_element?(view, "[data-testid=board-stat-awaiting]")
      refute has_element?(view, "[data-testid^=board-column-]")
      refute has_element?(view, "[data-testid=board-runners]")
      refute has_element?(view, "[data-testid=board-activity]")
    end

    test "the activity tab lists the twenty latest tasks", ctx do
      for n <- 1..21, do: create_task(ctx, "Tarefa #{n}")

      {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}?aba=atividade")

      items =
        view
        |> element("[data-testid=board-activity]")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("li")

      assert Enum.count(items) == 20
      refute has_element?(view, "[data-testid=board-stat-running]")
      refute has_element?(view, "[data-testid^=board-column-]")
      refute has_element?(view, "[data-testid=board-runners]")
    end

    test "the runners tab shows the runners and nothing else", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}?aba=executores")

      assert has_element?(view, "[data-testid=board-runner-mac]")
      assert has_element?(view, "[data-testid=board-runner-status-mac]", "Offline")
      assert has_element?(view, "[data-testid=board-runners-link]")
      refute has_element?(view, "[data-testid=board-stat-running]")
      refute has_element?(view, "[data-testid^=board-column-]")
      refute has_element?(view, "[data-testid=board-activity]")
    end

    test "the counters on the tabs follow the workspace live, whatever tab is open", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}?aba=atividade")

      refute has_element?(view, "[data-testid=board-tab-count-decisoes]")
      refute has_element?(view, "[data-testid=board-tab-count-visao]")
      assert has_element?(view, "[data-testid=board-tab-count-executores]", "0/1")

      tracker = spawn(fn -> Process.sleep(:infinity) end)
      {:ok, _ref} = RunnerStatus.track(tracker, ctx.runner)

      assert eventually(fn ->
               has_element?(view, "[data-testid=board-tab-count-executores]", "1/1")
             end)

      task = create_task(ctx, "Pede ajuda")
      finish_current(ctx, task, %{"status" => "bloqueado", "resumo" => "Qual?"})

      assert eventually(fn ->
               has_element?(view, "[data-testid=board-tab-count-decisoes]", "1")
             end)

      # Only a running task is stopped by its runner going offline.
      create_task(ctx, "Fica rodando")
      refute has_element?(view, "[data-testid=board-tab-count-visao]")

      Process.exit(tracker, :kill)

      assert eventually(fn ->
               has_element?(view, "[data-testid=board-tab-count-executores]", "0/1")
             end)

      assert eventually(fn ->
               has_element?(view, "[data-testid=board-tab-count-visao]", "1")
             end)
    end

    test "alerts on a task whose runner is offline", ctx do
      task = create_task(ctx, "Parada")
      {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}")
      assert has_element?(view, "[data-testid=board-alert-offline-#{task.id}]", "Parada")
      assert has_element?(view, "[data-testid=board-alert-offline-#{task.id}]", "mac")
      assert has_element?(view, "[data-testid=board-tab-count-visao]", "1")
    end

    test "the overview keeps its alerts to itself", ctx do
      task = create_task(ctx, "Parada")
      {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}?aba=decisoes")
      refute has_element?(view, "[data-testid=board-alert-offline-#{task.id}]")
      assert has_element?(view, "[data-testid=board-tab-count-visao]", "1")
    end

    test "alerts on a task whose runner's account is near its usage limits", ctx do
      task = create_task(ctx, "Perto do limite")

      {:ok, _} =
        PipeMaestro.Runners.record_rate_limit(ctx.runner, %{
          "status" => "allowed_warning",
          "utilization" => %{"five_hour" => 0.95}
        })

      {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}")
      assert has_element?(view, "[data-testid=board-alert-limit-#{task.id}]", "Perto do limite")
      assert has_element?(view, "[data-testid=board-alert-limit-#{task.id}]", "mac")
    end

    test "the offline alert comes and goes with the runner's presence, live", ctx do
      tracker = spawn(fn -> Process.sleep(:infinity) end)
      {:ok, _ref} = RunnerStatus.track(tracker, ctx.runner)
      task = create_task(ctx, "Acompanha o runner")

      {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}")
      refute has_element?(view, "[data-testid=board-alert-offline-#{task.id}]")

      Process.exit(tracker, :kill)

      assert eventually(fn ->
               has_element?(view, "[data-testid=board-alert-offline-#{task.id}]", "mac")
             end)

      back = spawn(fn -> Process.sleep(:infinity) end)
      {:ok, _ref} = RunnerStatus.track(back, ctx.runner)

      assert eventually(fn ->
               not has_element?(view, "[data-testid=board-alert-offline-#{task.id}]")
             end)

      Process.exit(back, :kill)
    end

    test "alerts on an online runner that is degraded, and why, live", ctx do
      tracker = spawn(fn -> Process.sleep(:infinity) end)
      {:ok, _ref} = RunnerStatus.track(tracker, ctx.runner)

      {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}")
      refute has_element?(view, "[data-testid=board-alert-degraded-mac]")

      {:ok, _} =
        PipeMaestro.RunnerTelemetry.record_health(ctx.runner, %{
          "at" => DateTime.to_iso8601(DateTime.utc_now()),
          "disk_free_bytes" => 1024 ** 3,
          "disk_total_bytes" => 100 * 1024 ** 3
        })

      RunnerStatus.notify_changed(ctx.workspace.id)

      assert eventually(fn ->
               has_element?(view, "[data-testid=board-alert-degraded-mac]", "pouco disco livre")
             end)

      Process.exit(tracker, :kill)

      assert eventually(fn ->
               not has_element?(view, "[data-testid=board-alert-degraded-mac]")
             end)
    end

    test "the limit alert shows as soon as a rate_limit is recorded, live", ctx do
      task = create_task(ctx, "Perto do limite ao vivo")
      {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}")
      refute has_element?(view, "[data-testid=board-alert-limit-#{task.id}]")

      {:ok, _} =
        Runners.record_rate_limit(ctx.runner, %{
          "status" => "allowed_warning",
          "utilization" => %{"five_hour" => 0.9}
        })

      RunnerStatus.notify_changed(ctx.workspace.id)

      assert eventually(fn ->
               has_element?(view, "[data-testid=board-alert-limit-#{task.id}]", "mac")
             end)
    end

    test "the limit alert goes away by itself when the limit resets", ctx do
      task = create_task(ctx, "Limite renova")
      resets_at = DateTime.utc_now(:second) |> DateTime.add(2) |> DateTime.to_unix()

      {:ok, _} =
        Runners.record_rate_limit(ctx.runner, %{
          "status" => "allowed_warning",
          "utilization" => %{"five_hour" => 0.9},
          "resets_at" => resets_at
        })

      {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}")
      assert has_element?(view, "[data-testid=board-alert-limit-#{task.id}]")

      # No event arrives: the board itself knows when the limit resets.
      assert eventually(
               fn -> not has_element?(view, "[data-testid=board-alert-limit-#{task.id}]") end,
               250
             )
    end

    test "filters by pipeline, runner, project and person, in the URL", ctx do
      other = pipeline_fixture(ctx.workspace, %{"name" => "Outro"})
      a = create_task(ctx, "Na app")
      b = create_task(ctx, "Nas notas", %{"directory" => "notas", "pipeline_id" => other.id})
      slug = ctx.workspace.slug
      app_id = project_on(ctx.runner, "app").id

      {:ok, view, _html} = live(ctx.conn, ~p"/w/#{slug}?aba=tarefas")
      assert has_element?(view, "[data-testid=board-task-#{a.id}]")
      assert has_element?(view, "[data-testid=board-task-#{b.id}]")

      view |> form("#board-filters", filters: %{pipeline: "Outro"}) |> render_change()
      assert_patch(view, ~p"/w/#{slug}?aba=tarefas&pipeline=Outro")
      refute has_element?(view, "[data-testid=board-task-#{a.id}]")
      assert has_element?(view, "[data-testid=board-task-#{b.id}]")

      view
      |> form("#board-filters", filters: %{pipeline: "", project_id: app_id})
      |> render_change()

      assert_patch(view, ~p"/w/#{slug}?aba=tarefas&project_id=#{app_id}")
      assert has_element?(view, "[data-testid=board-task-#{a.id}]")
      refute has_element?(view, "[data-testid=board-task-#{b.id}]")

      view
      |> form("#board-filters",
        filters: %{project_id: "", user_id: ctx.user.id, runner_id: ctx.runner.id}
      )
      |> render_change()

      assert_patch(
        view,
        ~p"/w/#{slug}?aba=tarefas&runner_id=#{ctx.runner.id}&user_id=#{ctx.user.id}"
      )

      assert has_element?(view, "[data-testid=board-task-#{a.id}]")
      assert has_element?(view, "[data-testid=board-task-#{b.id}]")
    end

    test "the filters come from the URL, so a reload or a shared link keeps them", ctx do
      other = pipeline_fixture(ctx.workspace, %{"name" => "Outro"})
      a = create_task(ctx, "Na app")
      b = create_task(ctx, "Nas notas", %{"directory" => "notas", "pipeline_id" => other.id})
      notes_id = project_on(ctx.runner, "notas").id

      {:ok, view, _html} =
        live(
          ctx.conn,
          ~p"/w/#{ctx.workspace.slug}?aba=tarefas&pipeline=Outro&project_id=#{notes_id}"
        )

      refute has_element?(view, "[data-testid=board-task-#{a.id}]")
      assert has_element?(view, "[data-testid=board-task-#{b.id}]")
      assert has_element?(view, "#board-filters option[value=Outro][selected]")
      assert has_element?(view, ~s(#board-filters option[value="#{notes_id}"][selected]))
    end

    test "a filter that matches nothing in the URL leaves the columns empty", ctx do
      create_task(ctx, "Na app")

      {:ok, view, _html} =
        live(ctx.conn, ~p"/w/#{ctx.workspace.slug}?aba=tarefas&project_id=nao-e-um-id")

      assert has_element?(view, "[data-testid=board-column-running]", "Nenhuma tarefa")
    end
  end

  describe "the tabs" do
    test "the overview is the default, and an unknown tab falls back to it", %{
      conn: conn,
      workspace: workspace
    } do
      for path <- [~p"/w/#{workspace.slug}", ~p"/w/#{workspace.slug}?aba=inexistente"] do
        {:ok, view, _html} = live(conn, path)
        assert has_element?(view, "[data-testid=board-tabs]")
        assert has_element?(view, ~s([data-testid=board-tab-visao][aria-selected=true]))
        refute has_element?(view, ~s([data-testid=board-tab-tarefas][aria-selected=true]))
        assert has_element?(view, "[data-testid=board-stat-running]")
        refute has_element?(view, "[data-testid^=board-column-]")
      end
    end

    test "every tab is a live patch that marks itself active", %{
      conn: conn,
      workspace: workspace
    } do
      {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}")

      for {id, testid} <- [
            {"tarefas", "board-column-running"},
            {"decisoes", "board-no-decisions"},
            {"atividade", "board-activity"},
            {"executores", "board-no-runners"}
          ] do
        view |> element("[data-testid=board-tab-#{id}]") |> render_click()
        assert_patch(view, ~p"/w/#{workspace.slug}?aba=#{id}")
        assert has_element?(view, ~s([data-testid=board-tab-#{id}][aria-selected=true]))
        refute has_element?(view, ~s([data-testid=board-tab-visao][aria-selected=true]))
        assert has_element?(view, "[data-testid=#{testid}]")
      end

      view |> element("[data-testid=board-tab-visao]") |> render_click()
      assert_patch(view, ~p"/w/#{workspace.slug}")
      assert has_element?(view, "[data-testid=board-stat-running]")
    end
  end

  test "an empty workspace points to the first task", %{conn: conn, workspace: workspace} do
    {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}")
    assert has_element?(view, "[data-testid=board-overview-no-decisions]")

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
    {:ok, _} = PipeMaestro.Workspaces.add_member(other, user)

    {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}")

    assert has_element?(view, ~s(#workspace-switcher a[href="/w/#{other.slug}"]))
  end

  test "a revoked session leaves the board", %{conn: conn, workspace: workspace, user: user} do
    {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}")

    PipeMaestroWeb.UserAuth.disconnect_user(user)

    assert_redirect(view, ~p"/login")
  end

  test "anonymous visitors are sent to sign in", %{workspace: workspace} do
    conn = get(build_conn(), ~p"/w/#{workspace.slug}")
    assert redirected_to(conn) == ~p"/login"
  end

  test "shows the workspace's real runners, live", %{conn: conn, workspace: workspace, user: user} do
    {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}?aba=executores")
    assert has_element?(view, "[data-testid=board-no-runners]")

    {_runner, _token} = runner_fixture(workspace, user, %{name: "build-01"})
    PipeMaestroWeb.RunnerStatus.notify_changed(workspace.id)

    assert render(view) =~ "build-01"
    assert has_element?(view, "[data-testid=board-runner-status-build-01]", "Offline")
    assert has_element?(view, "[data-testid=board-tab-count-executores]", "0/1")
  end

  defp eventually(fun, attempts \\ 50) do
    cond do
      fun.() -> true
      attempts == 0 -> false
      true -> Process.sleep(20) && eventually(fun, attempts - 1)
    end
  end
end
