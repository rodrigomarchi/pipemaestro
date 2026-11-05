defmodule PipeMaestro.Projects.Project do
  @moduledoc """
  A workspace's project: one code directory of one runner (`runner`), the
  only choice of where work runs. It keeps the commands that
  set up a task's worktree, test and lint the code, the paths to clone into a
  new worktree (dependencies, build output) and notes for the agents.

  The directory must be one the runner offers; the same directory may be a
  project on another runner, never twice on one. A project whose runner was
  deleted has none (`runner_id` `nil`) and takes no work until it gets one.

  A task started in the project keeps a `snapshot/1` of it, so editing the
  project never changes a task already running. Prompts reach it as
  `{{projeto.*}}` (`PipeMaestro.Pipelines.Prompt`).

  With a `github_repo` (`dono/repo`) and a `trigger_label`, a GitHub webhook
  starts a task with the `trigger_pipeline` when an issue of the repository
  gets the label, on behalf of `trigger_user` (who set the trigger up). With
  `trigger_mode` `"triage"`, the agent writes the task from the issue first
  (`PipeMaestro.Proposals`), for a person to review before it starts.
  """
  use PipeMaestro.Schema

  import Ecto.Changeset
  import Ecto.Query, only: [from: 2]

  alias PipeMaestro.Repo
  alias PipeMaestro.Runners.Runner
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
          github_repo: String.t() | nil,
          trigger_label: String.t() | nil,
          trigger_mode: String.t(),
          trigger_pipeline_id: Ecto.UUID.t() | nil,
          trigger_user_id: Ecto.UUID.t() | nil,
          workspace_id: Ecto.UUID.t() | nil,
          workspace: Workspace.t() | Ecto.Association.NotLoaded.t(),
          runner_id: Ecto.UUID.t() | nil,
          runner: Runner.t() | Ecto.Association.NotLoaded.t() | nil,
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
    field :github_repo, :string
    field :trigger_label, :string
    field :trigger_mode, :string, default: "task"
    field :trigger_pipeline_id, :binary_id
    field :trigger_user_id, :binary_id

    belongs_to :workspace, Workspace
    belongs_to :runner, Runner

    timestamps()
  end

  @doc ~s(What a labeled issue does: "task" starts one, "triage" has the agent write it first.)
  @spec trigger_modes() :: [String.t()]
  def trigger_modes, do: ~w(task triage)

  @doc """
  Changeset for a project. The paths to clone may come as one per line
  (`copy_paths_text`, from a form). The runner must be an active one of the
  project's workspace and offer the directory.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(project, attrs) do
    project
    |> cast(attrs, [
      :name,
      :runner_id,
      :directory,
      :setup_command,
      :test_command,
      :lint_command,
      :copy_paths,
      :copy_paths_text,
      :notes,
      :github_repo,
      :trigger_label,
      :trigger_mode,
      :trigger_pipeline_id
    ])
    |> validate_inclusion(:trigger_mode, trigger_modes())
    |> update_change(:github_repo, &String.downcase(String.trim(&1)))
    |> validate_format(:github_repo, ~r{^[\w.-]+/[\w.-]+$}, message: "use dono/repositório")
    |> validate_length(:trigger_label, max: 50)
    |> validate_trigger()
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name], message: "dê um nome ao projeto")
    |> validate_required([:runner_id], message: "escolha o runner do projeto")
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
    |> validate_runner()
    |> unique_constraint(:directory,
      name: :projects_workspace_id_runner_id_directory_index,
      message: "esse runner já tem um projeto nessa pasta"
    )
    |> unsafe_validate_unique([:workspace_id, :runner_id, :directory], Repo,
      message: "esse runner já tem um projeto nessa pasta",
      error_key: :directory
    )
    |> unique_constraint(:github_repo,
      name: :projects_workspace_id_github_repo_index,
      message: "outro projeto já usa esse repositório"
    )
    |> unsafe_validate_unique([:workspace_id, :github_repo], Repo,
      message: "outro projeto já usa esse repositório",
      error_key: :github_repo
    )
  end

  # Only checked when the runner or the directory changes: a project whose
  # runner stopped offering the directory can still be edited.
  defp validate_runner(changeset) do
    runner_id = get_field(changeset, :runner_id)
    changed? = changed?(changeset, :runner_id) or changed?(changeset, :directory)

    if not changed? or is_nil(runner_id) or not valid?(changeset, :directory),
      do: changeset,
      else: check_runner(changeset, active_runner(get_field(changeset, :workspace_id), runner_id))
  end

  defp check_runner(changeset, nil),
    do: add_error(changeset, :runner_id, "não é um runner ativo deste workspace")

  defp check_runner(changeset, runner) do
    if Runner.offers?(runner, get_field(changeset, :directory)),
      do: changeset,
      else: add_error(changeset, :directory, "o runner não oferece esse diretório")
  end

  defp valid?(changeset, field), do: not Keyword.has_key?(changeset.errors, field)

  defp active_runner(workspace_id, runner_id) do
    Repo.one(
      from r in Runner,
        where: r.id == ^runner_id and r.workspace_id == ^workspace_id and is_nil(r.revoked_at)
    )
  end

  # A blank text (cast to nil) clears the paths; no text leaves them alone.
  # A trigger needs the repository, the label and the pipeline together.
  defp validate_trigger(changeset) do
    if get_field(changeset, :github_repo) || get_field(changeset, :trigger_label),
      do:
        validate_required(changeset, [:github_repo, :trigger_label, :trigger_pipeline_id],
          message: "o gatilho do GitHub precisa do repositório, da label e do pipeline"
        ),
      else: changeset
  end

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
