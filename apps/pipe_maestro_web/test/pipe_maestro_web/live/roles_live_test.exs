defmodule PipeMaestroWeb.RolesLiveTest do
  use PipeMaestroWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias PipeMaestro.Tasks

  setup %{conn: conn} do
    workspace = workspace_fixture(%{name: "Acme"})
    admin = member_fixture(workspace, %{name: "Ana Admin"})
    member = member_fixture(workspace, %{name: "Beto Membro"})
    %{conn: log_in_user(conn, member), workspace: workspace, admin: admin, member: member}
  end

  test "a member sees the pipelines and projects but cannot change them", ctx do
    pipeline = pipeline_fixture(ctx.workspace, %{"name" => "Meu"})

    {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/pipelines")
    assert has_element?(view, "[data-testid=pipeline-Meu]")
    refute has_element?(view, "[data-testid=new-pipeline]")
    refute has_element?(view, "[data-testid=pipeline-edit-Meu]")
    refute has_element?(view, "[data-testid=pipeline-delete-Meu]")
    assert has_element?(view, "[data-testid=pipeline-export-Meu]")

    assert {:error, {:live_redirect, %{to: path, flash: %{"error" => _}}}} =
             live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/pipelines/#{pipeline.id}/edit")

    assert path == "/w/#{ctx.workspace.slug}/pipelines"

    {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/projects")
    refute has_element?(view, "[data-testid=new-project]")

    assert {:error, {:live_redirect, _}} =
             live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/projects/new")
  end

  test "a member cannot rename or revoke runners", ctx do
    runner_fixture(ctx.workspace, ctx.admin, %{name: "mac"})
    {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/runners")
    assert has_element?(view, "[data-testid=runner-mac]")
    refute has_element?(view, "[data-testid=runner-revoke-mac]")
    refute has_element?(view, "[data-testid=connect-runner]")
  end

  test "a member cancels their own tasks, not someone else's", ctx do
    {runner, _token} = runner_fixture(ctx.workspace, ctx.admin, %{name: "mac"})
    with_directories(runner, [%{"name" => "app", "git" => true}])
    pipeline = pipeline_fixture(ctx.workspace)

    attrs = %{
      "title" => "T",
      "prompt" => "p",
      "pipeline_id" => pipeline.id,
      "runner_id" => runner.id,
      "directory" => "app"
    }

    {:ok, mine} = Tasks.create_task(ctx.member, ctx.workspace, attrs)
    {:ok, theirs} = Tasks.create_task(ctx.admin, ctx.workspace, attrs)

    {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/tasks/#{mine.id}")
    assert has_element?(view, "[data-testid=task-cancel]")

    {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/tasks/#{theirs.id}")
    refute has_element?(view, "[data-testid=task-cancel]")
    assert render_click(view, "cancel") =~ "não pode cancelar"
    assert Tasks.get_task!(ctx.workspace, theirs.id).status == :running
  end
end
