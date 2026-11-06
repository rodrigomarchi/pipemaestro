defmodule PipeMaestro.ProjectsTest do
  use PipeMaestro.DataCase, async: true

  import PipeMaestro.Fixtures

  alias PipeMaestro.Projects
  alias PipeMaestro.Projects.Project

  @attrs %{
    "name" => "Retro Hex Chat",
    "directory" => "retro_hex_chat",
    "setup_command" => "mix deps.get && mix compile",
    "test_command" => "mix test",
    "lint_command" => "mix credo --strict",
    "copy_paths_text" => "deps\n_build\n\n",
    "notes" => "Usa Postgres na porta 5442."
  }

  setup do
    workspace = workspace_fixture()
    {runner, _token} = runner_fixture(workspace, member_fixture(workspace))
    runner = with_directories(runner, [%{"name" => "retro_hex_chat", "git" => true}])
    %{workspace: workspace, attrs: Map.put(@attrs, "runner_id", runner.id)}
  end

  test "create, list, find, update, delete", %{workspace: workspace, attrs: attrs} do
    assert {:ok, %Project{} = project} = Projects.create_project(workspace, attrs)
    assert project.copy_paths == ["deps", "_build"]
    assert [%Project{id: id}] = Projects.list_projects(workspace)
    assert id == project.id
    assert Projects.get_project(workspace, project.id).id == project.id
    assert Projects.get_project(workspace, Ecto.UUID.generate()) == nil

    assert {:ok, %Project{test_command: "mix test --warnings-as-errors"}} =
             Projects.update_project(project, %{"test_command" => "mix test --warnings-as-errors"})

    assert {:ok, _} = Projects.delete_project(project)
    assert Projects.list_projects(workspace) == []
  end

  test "validates name, runner, directory and paths, one project per runner directory", %{
    workspace: workspace,
    attrs: attrs
  } do
    assert {:error, changeset} = Projects.create_project(workspace, %{})
    assert %{name: [_], runner_id: [_], directory: [_]} = errors_on(changeset)

    assert {:error, changeset} =
             Projects.create_project(workspace, %{attrs | "directory" => "../etc"})

    assert %{directory: [_]} = errors_on(changeset)

    assert {:error, changeset} =
             Projects.create_project(workspace, %{attrs | "copy_paths_text" => "/abs\n../x"})

    assert %{copy_paths: [_]} = errors_on(changeset)

    {:ok, _} = Projects.create_project(workspace, attrs)

    assert {:error, changeset} =
             Projects.create_project(workspace, %{attrs | "name" => "Outro nome"})

    assert %{directory: ["esse runner já tem um projeto nessa pasta"]} = errors_on(changeset)
  end

  test "the snapshot a task keeps and the setup a runner gets", %{
    workspace: workspace,
    attrs: attrs
  } do
    {:ok, project} = Projects.create_project(workspace, attrs)

    assert Project.snapshot(project) == %{
             "name" => "Retro Hex Chat",
             "setup_command" => "mix deps.get && mix compile",
             "test_command" => "mix test",
             "lint_command" => "mix credo --strict",
             "copy_paths" => ["deps", "_build"],
             "notes" => "Usa Postgres na porta 5442."
           }

    assert Project.setup(Project.snapshot(project)) == %{
             "command" => "mix deps.get && mix compile",
             "copy" => ["deps", "_build"]
           }

    {:ok, bare} =
      Projects.update_project(project, %{"setup_command" => "", "copy_paths_text" => ""})

    assert Project.setup(Project.snapshot(bare)) == nil
    assert Project.setup(nil) == nil
  end

  test "a workspace does not see another's projects", %{workspace: workspace, attrs: attrs} do
    {:ok, project} = Projects.create_project(workspace, attrs)
    other = workspace_fixture()

    assert Projects.list_projects(other) == []
    assert Projects.get_project(other, project.id) == nil
    assert_raise Ecto.NoResultsError, fn -> Projects.get_project!(other, project.id) end
  end
end
