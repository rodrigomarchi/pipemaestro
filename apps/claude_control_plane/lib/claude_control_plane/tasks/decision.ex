defmodule ClaudeControlPlane.Tasks.Decision do
  @moduledoc """
  A decision a person took on a task waiting for one: the question (why it
  paused), the options the agent proposed (`opcoes` in its structured
  output), what was done (`action`: retry the stage, move on, cancel), the
  option chosen, the instructions given, who decided and when.
  """
  use ClaudeControlPlane.Schema

  alias ClaudeControlPlane.Accounts.User
  alias ClaudeControlPlane.Tasks.Task

  @type action :: :retry | :advance | :cancel

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          stage_index: non_neg_integer(),
          question: String.t() | nil,
          options: [String.t()],
          action: action(),
          choice: String.t() | nil,
          instructions: String.t() | nil,
          task_id: Ecto.UUID.t() | nil,
          task: Task.t() | Ecto.Association.NotLoaded.t(),
          decided_by_user_id: Ecto.UUID.t() | nil,
          decided_by_user: User.t() | Ecto.Association.NotLoaded.t() | nil,
          inserted_at: DateTime.t() | nil
        }

  schema "decisions" do
    field :stage_index, :integer
    field :question, :string
    field :options, {:array, :string}, default: []
    field :action, Ecto.Enum, values: [:retry, :advance, :cancel]
    field :choice, :string
    field :instructions, :string

    belongs_to :task, Task
    belongs_to :decided_by_user, User

    # Microseconds: decisions on a task are listed in the order they were taken.
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
