defmodule ClaudeControlPlane.Pipelines do
  @moduledoc """
  Pipelines: the ordered stages a task goes through, kept per workspace and
  editable from the platform. See `ClaudeControlPlane.Pipelines.Pipeline` for
  versioning and `ClaudeControlPlane.Pipelines.Prompt` for what a stage's run
  is given.
  """

  import Ecto.Query

  alias ClaudeControlPlane.Pipelines.{Pipeline, Templates, Yaml}
  alias ClaudeControlPlane.Repo
  alias ClaudeControlPlane.Workspaces.Workspace

  @doc "The workspace's pipelines, by name."
  @spec list_pipelines(Workspace.t()) :: [Pipeline.t()]
  def list_pipelines(%Workspace{id: workspace_id}) do
    Repo.all(from p in Pipeline, where: p.workspace_id == ^workspace_id, order_by: p.name)
  end

  @doc "One of the workspace's pipelines. Raises when it is not there."
  @spec get_pipeline!(Workspace.t(), Ecto.UUID.t()) :: Pipeline.t()
  def get_pipeline!(%Workspace{id: workspace_id}, id),
    do: Repo.get_by!(Pipeline, id: id, workspace_id: workspace_id)

  @doc "A changeset for the pipeline form."
  @spec change_pipeline(Pipeline.t(), map()) :: Ecto.Changeset.t()
  def change_pipeline(%Pipeline{} = pipeline, attrs \\ %{}),
    do: Pipeline.changeset(pipeline, attrs)

  @doc "Creates a pipeline in the workspace."
  @spec create_pipeline(Workspace.t(), map()) ::
          {:ok, Pipeline.t()} | {:error, Ecto.Changeset.t()}
  def create_pipeline(%Workspace{id: workspace_id}, attrs) do
    %Pipeline{workspace_id: workspace_id}
    |> Pipeline.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Saves a pipeline, bumping its version."
  @spec update_pipeline(Pipeline.t(), map()) :: {:ok, Pipeline.t()} | {:error, Ecto.Changeset.t()}
  def update_pipeline(%Pipeline{} = pipeline, attrs) do
    pipeline
    |> Pipeline.changeset(attrs)
    |> Ecto.Changeset.put_change(:version, pipeline.version + 1)
    |> Repo.update()
  end

  @doc "The pipeline as YAML (`ClaudeControlPlane.Pipelines.Yaml`)."
  @spec export_yaml(Pipeline.t()) :: String.t()
  def export_yaml(%Pipeline{} = pipeline), do: Yaml.to_yaml(pipeline)

  @doc "Creates a pipeline in the workspace from YAML written by `export_yaml/1`."
  @spec import_yaml(Workspace.t(), String.t()) ::
          {:ok, Pipeline.t()} | {:error, String.t() | Ecto.Changeset.t()}
  def import_yaml(%Workspace{} = workspace, yaml) do
    with {:ok, attrs} <- Yaml.from_yaml(yaml), do: create_pipeline(workspace, attrs)
  end

  @doc "Deletes a pipeline. Tasks that used it keep their snapshot."
  @spec delete_pipeline(Pipeline.t()) :: {:ok, Pipeline.t()}
  def delete_pipeline(%Pipeline{} = pipeline), do: Repo.delete(pipeline)

  @doc """
  Creates the ready-made pipelines (`ClaudeControlPlane.Pipelines.Templates`)
  the workspace does not have yet, by name.
  """
  @spec create_defaults(Workspace.t()) :: [Pipeline.t()]
  def create_defaults(%Workspace{} = workspace) do
    existing = workspace |> list_pipelines() |> MapSet.new(& &1.name)

    for attrs <- Templates.all(), not MapSet.member?(existing, attrs["name"]) do
      {:ok, pipeline} = create_pipeline(workspace, attrs)
      pipeline
    end
  end
end
