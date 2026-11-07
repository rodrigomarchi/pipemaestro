defmodule PipeMaestroWeb.NotificationLiveTest do
  use PipeMaestroWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias PipeMaestro.Accounts.Scope
  alias PipeMaestro.{Notifications, Repo, Tasks, Workspaces}
  alias PipeMaestro.Notifications.Notification

  setup :register_and_log_in_member

  setup %{workspace: workspace, user: user} do
    {runner, _token} = runner_fixture(workspace, user, %{name: "mac"})
    runner = with_directories(runner, [%{"name" => "app", "git" => true}])
    %{runner: runner, pipeline: pipeline_fixture(workspace)}
  end

  defp create_task(ctx, title) do
    {:ok, task} =
      Tasks.create_task(ctx.user, ctx.workspace, %{
        "title" => title,
        "prompt" => "faça",
        "pipeline_id" => ctx.pipeline.id,
        "project_id" => project_on(ctx.runner, "app").id
      })

    task
  end

  defp notification!(user, workspace, attrs) do
    Notification
    |> struct(
      Enum.into(attrs, %{
        workspace_id: workspace.id,
        user_id: user.id,
        kind: :task_succeeded,
        title: "Algo foi concluída"
      })
    )
    |> Repo.insert!()
  end

  defp item(subject_id, kind), do: "[data-testid=notifications-item-#{subject_id}-#{kind}]"

  test "lists the person's notifications in this workspace, and no one else's", ctx do
    read = create_task(ctx, "Lida")
    unread = create_task(ctx, "Nova")
    theirs = create_task(ctx, "Alheia")
    colleague = member_fixture(ctx.workspace, %{}, :member)
    other_workspace = workspace_fixture()
    {:ok, _} = Workspaces.add_member(other_workspace, ctx.user, :member)

    notification!(ctx.user, ctx.workspace, %{
      task_id: read.id,
      title: "Lida foi concluída",
      read_at: DateTime.utc_now(:second)
    })

    notification!(ctx.user, ctx.workspace, %{
      task_id: unread.id,
      kind: :task_awaiting_decision,
      title: "Nova aguarda decisão",
      body: "Qual **navegador**?"
    })

    notification!(colleague, ctx.workspace, %{task_id: theirs.id, title: "Alheia foi concluída"})
    notification!(ctx.user, other_workspace, %{title: "De outro workspace"})

    {:ok, view, html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/notifications")
    assert has_element?(view, "[data-testid=notifications-page]")

    assert has_element?(view, "#{item(read.id, "task-succeeded")}[data-unread=false]")

    assert has_element?(
             view,
             "#{item(unread.id, "task-awaiting-decision")}[data-unread=true]",
             "Nova aguarda decisão"
           )

    # The body is Markdown, shown rendered.
    assert has_element?(view, "#{item(unread.id, "task-awaiting-decision")} strong", "navegador")

    refute has_element?(view, item(theirs.id, "task-succeeded"))
    refute html =~ "De outro workspace"
  end

  test "filters the unread through the URL, so the filter survives a reload", ctx do
    read = create_task(ctx, "Lida")
    unread = create_task(ctx, "Nova")

    notification!(ctx.user, ctx.workspace, %{
      task_id: read.id,
      read_at: DateTime.utc_now(:second)
    })

    notification!(ctx.user, ctx.workspace, %{task_id: unread.id})
    slug = ctx.workspace.slug

    {:ok, view, _html} = live(ctx.conn, ~p"/w/#{slug}/notifications")
    view |> element("[data-testid=notifications-filter-unread]") |> render_click()
    assert_patch(view, ~p"/w/#{slug}/notifications?filtro=nao-lidas")
    refute has_element?(view, item(read.id, "task-succeeded"))
    assert has_element?(view, item(unread.id, "task-succeeded"))

    {:ok, view, _html} = live(ctx.conn, ~p"/w/#{slug}/notifications?filtro=nao-lidas")
    refute has_element?(view, item(read.id, "task-succeeded"))

    view |> element("[data-testid=notifications-filter-all]") |> render_click()
    assert_patch(view, ~p"/w/#{slug}/notifications")
    assert has_element?(view, item(read.id, "task-succeeded"))
  end

  test "marks all as read, and a click opens the task, read", ctx do
    first = create_task(ctx, "Uma")
    second = create_task(ctx, "Outra")
    notification!(ctx.user, ctx.workspace, %{task_id: first.id})
    notification!(ctx.user, ctx.workspace, %{task_id: second.id})
    slug = ctx.workspace.slug
    scope = ctx.user |> Scope.for_user() |> Scope.put_workspace(ctx.workspace, :admin)

    {:ok, view, _html} = live(ctx.conn, ~p"/w/#{slug}/notifications")
    view |> element(item(first.id, "task-succeeded")) |> render_click()
    assert_redirect(view, ~p"/w/#{slug}/tasks/#{first.id}")
    assert Notifications.count_unread(scope) == 1

    {:ok, view, _html} = live(ctx.conn, ~p"/w/#{slug}/notifications")
    view |> element("[data-testid=notifications-mark-all-read]") |> render_click()
    assert has_element?(view, "#{item(second.id, "task-succeeded")}[data-unread=false]")
    refute has_element?(view, "[data-testid=notifications-unread-count]")
    assert Notifications.count_unread(scope) == 0
  end

  test "loads more past the first page", ctx do
    now = DateTime.utc_now(:second)
    tasks = for n <- 1..25, do: create_task(ctx, "Tarefa #{n}")

    for {task, n} <- Enum.with_index(tasks, 1) do
      notification!(ctx.user, ctx.workspace, %{
        task_id: task.id,
        inserted_at: DateTime.add(now, -n, :minute)
      })
    end

    oldest = List.last(tasks)

    {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/notifications")
    refute has_element?(view, item(oldest.id, "task-succeeded"))

    view |> element("[data-testid=notifications-load-more]") |> render_click()
    assert has_element?(view, item(oldest.id, "task-succeeded"))
    refute has_element?(view, "[data-testid=notifications-load-more]")
  end

  test "says when there is nothing", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/notifications")
    assert has_element?(view, "[data-testid=notifications-empty-inbox]")
  end
end
