defmodule PipeMaestro.Projects do
  @moduledoc """
  Projects: what the platform knows about each code directory of the
  workspace (`PipeMaestro.Projects.Project`): how to set up a task's
  worktree, how to test and lint, what agents should know.
  """

  import Ecto.Query

  alias PipeMaestro.Projects.Project
  alias PipeMaestro.Repo
  alias PipeMaestro.Workspaces.Workspace

  @doc "The workspace's projects, by name."
  @spec list_projects(Workspace.t()) :: [Project.t()]
  def list_projects(%Workspace{id: workspace_id}) do
    Repo.all(from p in Project, where: p.workspace_id == ^workspace_id, order_by: p.name)
  end

  @doc "One of the workspace's projects. Raises when it is not there."
  @spec get_project!(Workspace.t(), Ecto.UUID.t()) :: Project.t()
  def get_project!(%Workspace{id: workspace_id}, id),
    do: Repo.get_by!(Project, id: id, workspace_id: workspace_id)

  @doc "The workspace's project for a directory, if there is one."
  @spec for_directory(Workspace.t(), String.t()) :: Project.t() | nil
  def for_directory(%Workspace{id: workspace_id}, directory),
    do: Repo.get_by(Project, workspace_id: workspace_id, directory: directory)

  @doc "A changeset for the project form."
  @spec change_project(Project.t(), map()) :: Ecto.Changeset.t()
  def change_project(%Project{} = project, attrs \\ %{}), do: Project.changeset(project, attrs)

  @doc "Creates a project in the workspace."
  @spec create_project(Workspace.t(), map()) :: {:ok, Project.t()} | {:error, Ecto.Changeset.t()}
  def create_project(%Workspace{id: workspace_id}, attrs) do
    %Project{workspace_id: workspace_id}
    |> Project.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Saves a project. Tasks already started keep their snapshot."
  @spec update_project(Project.t(), map()) :: {:ok, Project.t()} | {:error, Ecto.Changeset.t()}
  def update_project(%Project{} = project, attrs) do
    project
    |> Project.changeset(attrs)
    |> Repo.update()
  end

  @doc "Deletes a project. Tasks that used it keep their snapshot."
  @spec delete_project(Project.t()) :: {:ok, Project.t()} | {:error, Ecto.Changeset.t()}
  def delete_project(%Project{} = project), do: Repo.delete(project)
end
