defmodule PipeMaestro.Projects do
  @moduledoc """
  Projects: a runner and one of its code directories
  (`PipeMaestro.Projects.Project`), the only choice of where a task, a job
  or a proposal runs, and what the platform knows about it: how to set up a
  worktree, how to test and lint, what agents should know.
  """

  import Ecto.Query

  alias PipeMaestro.Accounts.User
  alias PipeMaestro.Audit
  alias PipeMaestro.Projects.Project
  alias PipeMaestro.Repo
  alias PipeMaestro.Runners.Runner
  alias PipeMaestro.Tasks.Task
  alias PipeMaestro.Workspaces.Workspace

  @typedoc """
  Whether a project can take work now: `:ok`, `:needs_runner` (it has none),
  `:directory_gone` (its runner no longer offers the directory) or
  `:runner_offline` (the work waits for the runner).
  """
  @type health :: :ok | :needs_runner | :directory_gone | :runner_offline

  @doc "The workspace's projects, by name, with their runners."
  @spec list_projects(Workspace.t()) :: [Project.t()]
  def list_projects(%Workspace{id: workspace_id}) do
    Repo.all(
      from p in Project,
        where: p.workspace_id == ^workspace_id,
        order_by: [p.name, p.directory],
        preload: :runner
    )
  end

  @doc "One of the workspace's projects, with its runner. Raises when it is not there."
  @spec get_project!(Workspace.t(), Ecto.UUID.t()) :: Project.t()
  def get_project!(%Workspace{id: workspace_id}, id),
    do: Project |> Repo.get_by!(id: id, workspace_id: workspace_id) |> Repo.preload(:runner)

  @doc """
  One of the workspace's projects, with its runner; `nil` when there is none
  with that id (or it is not an id).
  """
  @spec get_project(Workspace.t() | Ecto.UUID.t(), term()) :: Project.t() | nil
  def get_project(%Workspace{id: workspace_id}, id), do: get_project(workspace_id, id)

  def get_project(workspace_id, id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} ->
        Project
        |> Repo.get_by(id: id, workspace_id: workspace_id)
        |> Repo.preload(:runner)

      :error ->
        nil
    end
  end

  def get_project(_workspace_id, _id), do: nil

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

  @doc """
  Moves the project to another active runner of the workspace that offers its
  directory, recorded in the audit as `project.runner_switched` (`from`,
  `to`). Tasks already started keep their own runner; only new work goes to
  the new one.
  """
  @spec switch_runner(Project.t(), Ecto.UUID.t() | nil, User.t() | nil) ::
          {:ok, Project.t()} | {:error, Ecto.Changeset.t()}
  def switch_runner(%Project{} = project, runner_id, user) do
    previous = project.runner_id

    with {:ok, switched} <-
           project |> Project.changeset(%{"runner_id" => runner_id}) |> Repo.update() do
      Audit.record(project.workspace_id, user, "project.runner_switched", switched, %{
        "from" => previous,
        "to" => switched.runner_id
      })

      {:ok, Repo.preload(switched, :runner, force: true)}
    end
  end

  @doc "The workspace's active runners that offer the project's directory, by name."
  @spec runner_choices(Project.t()) :: [Runner.t()]
  def runner_choices(%Project{workspace_id: workspace_id, directory: directory}) do
    from(r in Runner,
      where: r.workspace_id == ^workspace_id and is_nil(r.revoked_at),
      order_by: r.name
    )
    |> Repo.all()
    |> Enum.filter(&Runner.offers?(&1, directory))
  end

  @doc """
  Whether the project can take work now (`t:health/0`), given the ids of the
  runners online.
  """
  @spec health(Project.t(), MapSet.t()) :: health()
  def health(%Project{runner_id: nil}, _online_runner_ids), do: :needs_runner

  def health(%Project{} = project, online_runner_ids) do
    project = Repo.preload(project, :runner)

    cond do
      is_nil(project.runner) -> :needs_runner
      not Runner.offers?(project.runner, project.directory) -> :directory_gone
      not MapSet.member?(online_runner_ids, project.runner_id) -> :runner_offline
      true -> :ok
    end
  end

  @doc """
  The context of a job that studies or runs in a disposable worktree of the
  project's directory (`scratch`, `PipeMaestroProtocol.Job`), set up as the
  project says.
  """
  @spec scratch_context(Project.t()) :: map()
  def scratch_context(%Project{} = project) do
    base = %{"directory" => project.directory, "scratch" => true}

    case project |> Project.snapshot() |> Project.setup() do
      nil -> base
      setup -> Map.put(base, "setup", setup)
    end
  end

  @doc "The project's newest tasks, at most `limit`."
  @spec recent_tasks(Project.t(), pos_integer()) :: [Task.t()]
  def recent_tasks(%Project{id: project_id}, limit) do
    Repo.all(
      from t in Task,
        where: t.project_id == ^project_id,
        order_by: [desc: t.inserted_at, desc: t.id],
        limit: ^limit
    )
  end

  @doc "Deletes a project. Tasks that used it keep their snapshot."
  @spec delete_project(Project.t()) :: {:ok, Project.t()} | {:error, Ecto.Changeset.t()}
  def delete_project(%Project{} = project), do: Repo.delete(project)
end
