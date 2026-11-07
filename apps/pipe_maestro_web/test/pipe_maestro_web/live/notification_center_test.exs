defmodule PipeMaestroWeb.NotificationCenterTest do
  use PipeMaestroWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias PipeMaestro.{Jobs, Notifications, Proposals, Repo, Runners, Tasks, Workspaces}
  alias PipeMaestro.Accounts.Scope
  alias PipeMaestro.Notifications.Notification

  # The member signed in (Ana Lima) is the workspace's first, so its admin.
  setup :register_and_log_in_member

  setup %{workspace: workspace, user: user} do
    {runner, _token} = runner_fixture(workspace, user, %{name: "mac"})

    {:ok, runner} =
      Runners.record_hello(
        runner,
        hello_fixture(%{
          directories: [%{"name" => "app", "git" => true}],
          capabilities: ["scratch"]
        })
      )

    %{runner: runner, pipeline: pipeline_fixture(workspace, %{"name" => "Duas etapas"})}
  end

  defp create_task(ctx, title, user \\ nil) do
    {:ok, task} =
      Tasks.create_task(user || ctx.user, ctx.workspace, %{
        "title" => title,
        "prompt" => "faça",
        "pipeline_id" => ctx.pipeline.id,
        "project_id" => project_on(ctx.runner, "app").id
      })

    task
  end

  # Plays the runner: starts the task's current job and reports its end.
  defp run_current(ctx, task, output \\ %{"status" => "ok", "resumo" => "feito"}) do
    task = Tasks.get_task!(ctx.workspace, task.id)
    job = (Enum.find(task.stage_runs, &(&1.status == :running)) || List.last(task.stage_runs)).job
    {:ok, _} = Jobs.mark_started(ctx.runner, job.id)

    {:ok, _} =
      Jobs.finish_job(ctx.runner, job.id, %{
        "status" => "succeeded",
        "exit_code" => 0,
        "structured_output" => output
      })

    Tasks.get_task!(ctx.workspace, task.id)
  end

  defp blocked_task(ctx, title),
    do: run_current(ctx, create_task(ctx, title), %{"status" => "bloqueado", "resumo" => "?"})

  # A notification of the signed-in member written straight to the table.
  defp notification!(ctx, attrs) do
    Notification
    |> struct(
      Enum.into(attrs, %{
        workspace_id: ctx.workspace.id,
        user_id: ctx.user.id,
        kind: :task_succeeded,
        title: "Algo foi concluída"
      })
    )
    |> Repo.insert!()
  end

  defp scope(ctx), do: ctx.user |> Scope.for_user() |> Scope.put_workspace(ctx.workspace, :admin)

  # The running list is reloaded a moment after a change (debounced).
  defp eventually(fun, tries \\ 40) do
    cond do
      fun.() ->
        true

      tries == 0 ->
        false

      true ->
        Process.sleep(25)
        eventually(fun, tries - 1)
    end
  end

  defp open_panel(view) do
    view |> element("[data-testid=notifications-bell]") |> render_click()
    assert has_element?(view, "[data-testid=notifications-panel]")
    view
  end

  defp open_inbox(view) do
    view |> open_panel() |> element("[data-testid=notifications-tab-inbox]") |> render_click()
    view
  end

  defp item(subject_id, kind), do: "[data-testid=notifications-item-#{subject_id}-#{kind}]"

  describe "the bell" do
    test "every workspace page shows it, with the unread count", ctx do
      slug = ctx.workspace.slug
      task = create_task(ctx, "Tela branca")
      notification!(ctx, %{task_id: task.id})

      paths =
        [
          "",
          "/decisions",
          "/usage",
          "/pull-requests",
          "/audit",
          "/secrets",
          "/integrations",
          "/runners",
          "/runners/#{ctx.runner.id}",
          "/jobs",
          "/tasks",
          "/tasks/#{task.id}",
          "/projects",
          "/pipelines",
          "/proposals",
          "/notifications"
        ]

      for path <- paths do
        {:ok, view, _html} = live(ctx.conn, "/w/#{slug}#{path}")
        assert has_element?(view, "[data-testid=notifications-bell]"), "no bell on #{path}"

        assert has_element?(view, "[data-testid=notifications-unread-count]", "1"),
               "no unread count on #{path}"
      end
    end

    test "says what it holds to a screen reader, and caps the count at 9+", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/usage")
      assert has_element?(view, "[data-testid=notifications-bell][aria-haspopup=dialog]")
      refute has_element?(view, "[data-testid=notifications-unread-count]")

      for _ <- 1..12, do: notification!(ctx, %{})

      {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/usage")
      assert has_element?(view, "[data-testid=notifications-unread-count]", "9+")
      assert has_element?(view, "[data-testid=notifications-bell][aria-label*='12 não lidas']")
    end

    test "a task that pauses raises the count live, and the toast still shows", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/runners")
      refute has_element?(view, "[data-testid=notifications-unread-count]")

      blocked_task(ctx, "Tela branca")

      assert has_element?(view, "[data-testid=notifications-unread-count]", "1")
      assert_push_event(view, "notify", %{title: "Tela branca aguarda decisão"})
      assert render(view) =~ "Tela branca aguarda decisão"
    end

    test "a dot shows while something runs, and goes when it ends", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/usage")
      refute has_element?(view, "[data-testid=notifications-activity-indicator]")

      task = create_task(ctx, "Tela branca")

      assert eventually(fn ->
               has_element?(view, "[data-testid=notifications-activity-indicator]")
             end)

      task = run_current(ctx, task)
      run_current(ctx, task)

      assert eventually(fn ->
               not has_element?(view, "[data-testid=notifications-activity-indicator]")
             end)
    end

    test "the page's own messages still reach it", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/runners")
      blocked_task(ctx, "Tela branca")
      assert has_element?(view, "[data-testid=notifications-unread-count]", "1")

      send(view.pid, :runners_changed)
      assert has_element?(view, "[data-testid=runner-mac]")
    end
  end

  describe "the panel" do
    test "opens over the page on the running tab, and closes leaving the page as it was", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/usage")
      refute has_element?(view, "[data-testid=notifications-panel]")

      open_panel(view)
      assert has_element?(view, "[data-testid=notifications-tab-active]")
      assert has_element?(view, "[data-testid=notifications-empty-active]", "Nada rodando agora")

      view |> element("[data-testid=notifications-close]") |> render_click()
      refute has_element?(view, "[data-testid=notifications-panel]")
      assert has_element?(view, "[data-testid=page-title]")
    end

    test "running: grouped, with the stage, runner, creator and time, kept up to date", ctx do
      {:ok, workspace} = Workspaces.update_workspace(ctx.workspace, %{"max_running_tasks" => 1})
      ctx = %{ctx | workspace: workspace}

      paused = blocked_task(ctx, "Parada")
      running = create_task(ctx, "Rodando")
      queued = create_task(ctx, "Na fila")

      {:ok, view, _html} = live(ctx.conn, ~p"/w/#{workspace.slug}/usage")
      open_panel(view)

      running_item = "[data-testid=notifications-active-item-#{running.id}]"

      assert has_element?(
               view,
               "[data-testid=notifications-group-running] #{running_item}",
               "Rodando"
             )

      assert has_element?(view, running_item, ~r/etapa 1 de 2/i)
      assert has_element?(view, running_item, "mac")
      assert has_element?(view, running_item, "Ana Lima")
      assert has_element?(view, "#{running_item} [phx-hook=Elapsed][data-since]")

      assert has_element?(
               view,
               "[data-testid=notifications-group-awaiting] [data-testid=notifications-active-item-#{paused.id}]"
             )

      assert has_element?(
               view,
               "[data-testid=notifications-group-queued] [data-testid=notifications-active-item-#{queued.id}]"
             )

      run_current(ctx, running)
      assert eventually(fn -> has_element?(view, running_item, ~r/etapa 2 de 2/i) end)
    end

    test "running: only mine, or everyone's", ctx do
      colleague = member_fixture(ctx.workspace, %{name: "Caio"}, :member)
      mine = create_task(ctx, "Minha")
      theirs = create_task(ctx, "Do Caio", colleague)

      {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/usage")
      open_panel(view)
      assert has_element?(view, "[data-testid=notifications-active-item-#{mine.id}]")
      assert has_element?(view, "[data-testid=notifications-active-item-#{theirs.id}]")

      view |> element("[data-testid=notifications-mine-toggle]") |> render_click()
      assert has_element?(view, "[data-testid=notifications-active-item-#{mine.id}]")
      refute has_element?(view, "[data-testid=notifications-active-item-#{theirs.id}]")
    end

    test "running: a proposal being written shows as one", ctx do
      {:ok, job} =
        Proposals.request("pipeline", ctx.user, ctx.workspace, %{
          "project_id" => project_on(ctx.runner, "app").id,
          "request" => "Um pipeline com PR"
        })

      {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/usage")
      open_panel(view)

      assert has_element?(
               view,
               "[data-testid=notifications-active-item-#{job.id}]",
               ~r/proposta/i
             )
    end

    test "inbox: a click opens the task and marks it read", ctx do
      task = blocked_task(ctx, "Tela branca")
      {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/usage")
      open_inbox(view)

      selector = item(task.id, "task-awaiting-decision")
      assert has_element?(view, "#{selector}[data-unread=true]", "Tela branca aguarda decisão")

      view |> element(selector) |> render_click()
      assert_redirect(view, ~p"/w/#{ctx.workspace.slug}/tasks/#{task.id}")
      assert Notifications.count_unread(scope(ctx)) == 0
    end

    test "inbox: a ready proposal opens the proposal", ctx do
      job = job_fixture(ctx.runner, ctx.user)

      notification!(ctx, %{
        kind: :proposal_ready,
        job_id: job.id,
        title: "Proposta de pipeline pronta"
      })

      {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/usage")
      open_inbox(view)

      view |> element(item(job.id, "proposal-ready")) |> render_click()
      assert_redirect(view, ~p"/w/#{ctx.workspace.slug}/proposals/#{job.id}")
    end

    test "inbox: marking all as read clears the badge", ctx do
      first = create_task(ctx, "Uma")
      second = create_task(ctx, "Outra")
      notification!(ctx, %{task_id: first.id})
      notification!(ctx, %{task_id: second.id})

      {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/usage")
      assert has_element?(view, "[data-testid=notifications-unread-count]", "2")
      open_inbox(view)

      view |> element("[data-testid=notifications-mark-all-read]") |> render_click()
      refute has_element?(view, "[data-testid=notifications-unread-count]")
      assert has_element?(view, "#{item(first.id, "task-succeeded")}[data-unread=false]")
    end

    test "inbox: pages with load more, and filters the unread", ctx do
      now = DateTime.utc_now(:second)
      tasks = for n <- 1..25, do: create_task(ctx, "Tarefa #{n}")

      for {task, n} <- Enum.with_index(tasks, 1) do
        notification!(ctx, %{
          task_id: task.id,
          title: "Tarefa #{n} foi concluída",
          inserted_at: DateTime.add(now, -n, :minute),
          read_at: if(n == 1, do: now)
        })
      end

      [newest | _] = tasks
      oldest = List.last(tasks)

      {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/usage")
      open_inbox(view)
      assert has_element?(view, item(newest.id, "task-succeeded"))
      refute has_element?(view, item(oldest.id, "task-succeeded"))

      view |> element("[data-testid=notifications-load-more]") |> render_click()
      assert has_element?(view, item(oldest.id, "task-succeeded"))
      refute has_element?(view, "[data-testid=notifications-load-more]")

      view |> element("[data-testid=notifications-filter-unread]") |> render_click()
      refute has_element?(view, item(newest.id, "task-succeeded"))

      view |> element("[data-testid=notifications-filter-all]") |> render_click()
      assert has_element?(view, item(newest.id, "task-succeeded"))
    end

    test "inbox: empty, with a way to every notification", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/usage")
      open_inbox(view)

      assert has_element?(view, "[data-testid=notifications-empty-inbox]")

      assert has_element?(
               view,
               "[data-testid=notifications-see-all][href='/w/#{ctx.workspace.slug}/notifications']"
             )
    end

    test "inbox: a notification arriving with the panel open shows at the top", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/usage")
      open_inbox(view)

      task = blocked_task(ctx, "Tela branca")
      assert has_element?(view, item(task.id, "task-awaiting-decision"))
      refute has_element?(view, "[data-testid=notifications-empty-inbox]")
    end
  end
end
