defmodule PipeMaestro.Notifications.Notification do
  @moduledoc """
  Something that happened that a person of a workspace should know about,
  kept in their inbox until read (`PipeMaestro.Notifications`).

  `kind` says what happened: a task paused for a decision
  (`:task_awaiting_decision`), ended (`:task_succeeded`, `:task_failed`,
  `:task_canceled`), its pull request was merged by the platform
  (`:task_merged`) or the merge stopped (`:task_merge_blocked`), or a proposal is ready for review (`:proposal_ready`)
  or failed (`:proposal_failed`).
  `task_id` or `job_id` is what it leads to; `body` is Markdown.
  """
  use PipeMaestro.Schema

  alias PipeMaestro.Accounts.User
  alias PipeMaestro.Jobs.Job
  alias PipeMaestro.Tasks.Task
  alias PipeMaestro.Workspaces.Workspace

  @kinds [
    :task_awaiting_decision,
    :task_succeeded,
    :task_failed,
    :task_canceled,
    :task_merged,
    :task_merge_blocked,
    :proposal_ready,
    :proposal_failed
  ]

  @type kind ::
          :task_awaiting_decision
          | :task_succeeded
          | :task_failed
          | :task_canceled
          | :task_merged
          | :task_merge_blocked
          | :proposal_ready
          | :proposal_failed

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          kind: kind() | nil,
          title: String.t() | nil,
          body: String.t() | nil,
          read_at: DateTime.t() | nil,
          workspace_id: Ecto.UUID.t() | nil,
          user_id: Ecto.UUID.t() | nil,
          task_id: Ecto.UUID.t() | nil,
          job_id: Ecto.UUID.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "notifications" do
    field :kind, Ecto.Enum, values: @kinds
    field :title, :string
    field :body, :string
    field :read_at, :utc_datetime

    belongs_to :workspace, Workspace
    belongs_to :user, User
    belongs_to :task, Task
    belongs_to :job, Job

    timestamps()
  end

  @doc "The kinds of notification."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds
end
