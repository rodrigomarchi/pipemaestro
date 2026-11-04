defmodule PipeMaestro.Tasks.StageRun do
  @moduledoc """
  One attempt at one stage of a task, run as a job. It records the
  instructions a person added (when the attempt came from a decision) and what
  the gate found: `passed`, `failed` (an error) or `blocked` (the agent asked
  for a person), with the stage's summary, structured output and artifact.
  """
  use PipeMaestro.Schema

  alias PipeMaestro.Jobs.Job
  alias PipeMaestro.Tasks.Task

  @type status :: :running | :passed | :failed | :blocked | :canceled

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          index: non_neg_integer() | nil,
          key: String.t() | nil,
          name: String.t() | nil,
          attempt: pos_integer() | nil,
          instructions: String.t() | nil,
          feedback: String.t() | nil,
          status: status(),
          summary: String.t() | nil,
          structured_output: map() | nil,
          artifact: String.t() | nil,
          error: String.t() | nil,
          task_id: Ecto.UUID.t() | nil,
          task: Task.t() | Ecto.Association.NotLoaded.t(),
          job: Job.t() | Ecto.Association.NotLoaded.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "stage_runs" do
    field :index, :integer
    field :key, :string
    field :name, :string
    field :attempt, :integer
    field :instructions, :string
    field :feedback, :string

    field :status, Ecto.Enum,
      values: [:running, :passed, :failed, :blocked, :canceled],
      default: :running

    field :summary, :string
    field :structured_output, :map
    field :artifact, :string
    field :error, :string

    belongs_to :task, Task
    has_one :job, Job

    timestamps()
  end
end
