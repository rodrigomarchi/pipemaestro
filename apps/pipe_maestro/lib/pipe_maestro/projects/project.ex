defmodule PipeMaestro.Projects.Project do
  @moduledoc """
  A workspace's project: what the platform knows about one code directory,
  matched by name on whichever runner offers it. It keeps the commands that
  set up a task's worktree, test and lint the code, the paths to clone into a
  new worktree (dependencies, build output) and notes for the agents.

  A task started in the directory keeps a `snapshot/1` of it, so editing the
  project never changes a task already running. Prompts reach it as
  `{{projeto.*}}` (`PipeMaestro.Pipelines.Prompt`).

  The git host's repositories linked to it, whose issues become its tasks,
  are an integration's (`PipeMaestro.Integrations.LinkedRepo`).
  """
  use PipeMaestro.Schema

  import Ecto.Changeset

  alias PipeMaestro.Workspaces.Workspace
  alias PipeMaestroProtocol.Hello

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          name: String.t() | nil,
          directory: String.t() | nil,
          setup_command: String.t() | nil,
          test_command: String.t() | nil,
          lint_command: String.t() | nil,
          copy_paths: [String.t()],
          copy_paths_text: String.t() | nil,
          notes: String.t() | nil,
          workspace_id: Ecto.UUID.t() | nil,
          workspace: Workspace.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @snapshot_fields ~w(name setup_command test_command lint_command copy_paths notes)a

  schema "projects" do
    field :name, :string
    field :directory, :string
    field :setup_command, :string
    field :test_command, :string
    field :lint_command, :string
    field :copy_paths, {:array, :string}, default: []
    field :copy_paths_text, :string, virtual: true
    field :notes, :string

    belongs_to :workspace, Workspace

    timestamps()
  end

  @doc """
  Changeset for a project. The paths to clone may come as one per line
  (`copy_paths_text`, from a form).
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(project, attrs) do
    project
    |> cast(attrs, [
      :name,
      :directory,
      :setup_command,
      :test_command,
      :lint_command,
      :copy_paths,
      :copy_paths_text,
      :notes
    ])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name], message: "dê um nome ao projeto")
    |> validate_required([:directory], message: "informe o diretório")
    |> validate_length(:name, max: 80)
    |> validate_change(:directory, fn :directory, directory ->
      if Hello.valid_directory_name?(directory),
        do: [],
        else: [directory: "use o nome de um diretório da raiz do runner"]
    end)
    |> validate_length(:setup_command, max: 4_000)
    |> validate_length(:test_command, max: 4_000)
    |> validate_length(:lint_command, max: 4_000)
    |> validate_length(:notes, max: 4_000)
    |> parse_copy_paths()
    |> validate_change(:copy_paths, fn :copy_paths, paths ->
      if Enum.all?(paths, &inner_path?/1),
        do: [],
        else: [copy_paths: "use caminhos relativos ao diretório, sem .."]
    end)
    |> unique_constraint(:directory,
      name: :projects_workspace_id_directory_index,
      message: "já tem um projeto"
    )
    |> unsafe_validate_unique([:workspace_id, :directory], PipeMaestro.Repo,
      message: "já tem um projeto",
      error_key: :directory
    )
  end

  # A blank text (cast to nil) clears the paths; no text leaves them alone.
  defp parse_copy_paths(changeset) do
    case changeset.params do
      %{"copy_paths_text" => text} ->
        paths =
          (text || "")
          |> String.split("\n")
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        put_change(changeset, :copy_paths, paths)

      _no_text ->
        changeset
    end
  end

  defp inner_path?(path),
    do: Path.type(path) == :relative and ".." not in Path.split(path) and byte_size(path) <= 255

  @doc "What a task keeps of the project when it starts."
  @spec snapshot(t()) :: map()
  def snapshot(%__MODULE__{} = project) do
    Map.new(@snapshot_fields, &{Atom.to_string(&1), Map.fetch!(project, &1)})
  end

  @doc """
  The worktree setup a runner gets for a project snapshot, in the wire form of
  `PipeMaestroProtocol.Job`'s `setup`; `nil` when there is nothing to
  set up (the runner then picks the paths to clone on its own).
  """
  @spec setup(map() | nil) :: map() | nil
  def setup(nil), do: nil

  def setup(snapshot) do
    setup =
      %{"command" => blank_to_nil(snapshot["setup_command"]), "copy" => snapshot["copy_paths"]}
      |> Map.reject(fn {_key, value} -> value in [nil, []] end)

    if setup == %{}, do: nil, else: setup
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
