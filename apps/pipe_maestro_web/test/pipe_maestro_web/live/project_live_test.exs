defmodule PipeMaestroWeb.ProjectLiveTest do
  use PipeMaestroWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias PipeMaestro.Projects

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

    {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/projects/#{project.id}/edit")
    assert has_element?(view, "[data-testid=project-integrations-link]")

    PipeMaestro.FakeForgejo.start(repos: %{"acme/retro" => %{}})

    {:ok, _repo} =
      PipeMaestro.Integrations.link_repo(
        connection_fixture(workspace),
        user,
        %{"full_name" => "acme/retro", "project_id" => project.id},
        "https://pm.test/hook"
      )

    {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/projects/#{project.id}/edit")
    assert has_element?(view, "[data-testid=project-linked-repos]", "acme/retro")

    {:error, {:live_redirect, _}} =
      view
      |> form("#project-form", project: %{lint_command: "mix credo"})
      |> render_submit()

    assert Projects.get_project!(workspace, project.id).lint_command == "mix credo"

    {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/projects")
    view |> element("[data-testid=project-delete-retro_hex_chat]") |> render_click()
    assert has_element?(view, "[data-testid=no-projects]")
  end
end
