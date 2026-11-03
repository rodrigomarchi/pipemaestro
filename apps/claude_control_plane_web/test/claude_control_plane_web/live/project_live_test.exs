defmodule ClaudeControlPlaneWeb.ProjectLiveTest do
  use ClaudeControlPlaneWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ClaudeControlPlane.Projects

  setup :register_and_log_in_member

  test "creates, edits and deletes a project, offering the runners' directories", %{
    conn: conn,
    workspace: workspace,
    user: user
  } do
    {runner, _token} = runner_fixture(workspace, user)
    with_directories(runner, [%{"name" => "retro_hex_chat", "git" => true}])

    {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/projects")
    assert has_element?(view, "[data-testid=no-projects]")

    {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/projects/new")
    assert view |> element("[data-testid=project-directory]") |> render() =~ "retro_hex_chat"

    html =
      view
      |> form("#project-form", project: %{name: "", directory: "retro_hex_chat"})
      |> render_submit()

    assert html =~ "dê um nome ao projeto"

    {:error, {:live_redirect, %{to: path}}} =
      view
      |> form("#project-form",
        project: %{
          name: "Retro Hex Chat",
          directory: "retro_hex_chat",
          setup_command: "mix deps.get",
          test_command: "mix test",
          copy_paths_text: "deps\n_build"
        }
      )
      |> render_submit()

    assert path == "/w/#{workspace.slug}/projects"
    [project] = Projects.list_projects(workspace)
    assert project.copy_paths == ["deps", "_build"]

    {:ok, view, _html} = live(conn, path)
    assert has_element?(view, "[data-testid=project-retro_hex_chat]", "Retro Hex Chat")
    assert has_element?(view, "[data-testid=project-retro_hex_chat]", "mix test")

    {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/projects/#{project.id}/edit")
    assert view |> element("[data-testid=project-copy-paths]") |> render() =~ "deps\n_build"

    pipeline = pipeline_fixture(workspace, %{"name" => "Fluxo"})
    {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/projects/#{project.id}/edit")

    assert has_element?(
             view,
             "[data-testid=project-webhook-url]",
             "/api/github/webhook/#{workspace.slug}"
           )

    {:error, {:live_redirect, _}} =
      view
      |> form("#project-form",
        project: %{
          lint_command: "mix credo",
          github_repo: "acme/retro",
          trigger_label: "claude",
          trigger_pipeline_id: pipeline.id
        }
      )
      |> render_submit()

    saved = Projects.get_project!(workspace, project.id)
    assert saved.lint_command == "mix credo"
    assert {saved.github_repo, saved.trigger_label} == {"acme/retro", "claude"}
    assert saved.trigger_user_id == user.id

    {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/projects")
    view |> element("[data-testid=project-delete-retro_hex_chat]") |> render_click()
    assert has_element?(view, "[data-testid=no-projects]")
  end
end
