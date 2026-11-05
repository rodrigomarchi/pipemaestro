defmodule PipeMaestro.Tasks.Decision do
  @moduledoc """
  A decision a person took on a task waiting for one: the question (why it
  paused), what was done (`action`: retry the stage, move on, cancel, or `correct`: a
  prompt run as a new stage of a task that ended), the
  instructions given, who decided and when.

  When the pause had a questionnaire (`PipeMaestro.Tasks.Questionnaire`),
  `questions` keeps its questions (`%{"perguntas" => [...]}`) and `answers`
  what the person answered (`%{"respostas" => [...]}`). `options` (the
  agent's `opcoes`) and `choice` (the one picked) are the older format,
  still read for decisions taken before questionnaires.
  """
  use PipeMaestro.Schema

  alias PipeMaestro.Accounts.User
  alias PipeMaestro.Tasks.Task

  @type action :: :retry | :advance | :cancel | :correct

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          stage_index: non_neg_integer(),
          question: String.t() | nil,
          options: [String.t()],
          action: action(),
          choice: String.t() | nil,
          instructions: String.t() | nil,
          questions: map() | nil,
          answers: map() | nil,
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
    field :action, Ecto.Enum, values: [:retry, :advance, :cancel, :correct]
    field :choice, :string
    field :instructions, :string
    field :questions, :map
    field :answers, :map

    belongs_to :task, Task
    belongs_to :decided_by_user, User

    # Microseconds: decisions on a task are listed in the order they were taken.
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
