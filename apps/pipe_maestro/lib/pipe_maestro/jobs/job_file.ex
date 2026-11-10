defmodule PipeMaestro.Jobs.JobFile do
  @moduledoc """
  A file a job left in its folder (`CP_FILES_DIR`) and its runner sent:
  a screenshot, a report, a CSV. `path` is relative to that folder and unique
  per job; sending it again replaces the file. It belongs to the job's
  workspace and, for a task's stage, to the stage run.

  `content` is never loaded by a query unless it asks for it
  (`PipeMaestro.Jobs.Files.get_for_download/2`), so listings stay light.

  Past its workspace's retention, a file loses its content (`content` is
  `nil`) and gets `pruned_at`; its path, size and type stay, so the task still
  names it.
  """
  use PipeMaestro.Schema

  alias PipeMaestro.Jobs.Job
  alias PipeMaestro.Tasks.StageRun
  alias PipeMaestro.Workspaces.Workspace

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          path: String.t() | nil,
          content_type: String.t() | nil,
          byte_size: non_neg_integer() | nil,
          sha256: String.t() | nil,
          content: binary() | nil,
          pruned_at: DateTime.t() | nil,
          workspace_id: Ecto.UUID.t() | nil,
          workspace: Workspace.t() | Ecto.Association.NotLoaded.t(),
          job_id: Ecto.UUID.t() | nil,
          job: Job.t() | Ecto.Association.NotLoaded.t(),
          stage_run_id: Ecto.UUID.t() | nil,
          stage_run: StageRun.t() | Ecto.Association.NotLoaded.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "job_files" do
    field :path, :string
    field :content_type, :string
    field :byte_size, :integer
    field :sha256, :string
    field :content, :binary, load_in_query: false
    field :pruned_at, :utc_datetime

    belongs_to :workspace, Workspace
    belongs_to :job, Job
    belongs_to :stage_run, StageRun

    timestamps()
  end

  @doc "Whether the retention emptied the file: it keeps its name, not its content."
  @spec pruned?(t()) :: boolean()
  def pruned?(%__MODULE__{pruned_at: pruned_at}), do: not is_nil(pruned_at)
end
