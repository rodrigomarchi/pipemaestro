defmodule PipeMaestro.Tasks.Task do
  @moduledoc """
  A task: a prompt worked through a pipeline's stages, one after another, by
  one runner in one of its directories.

  It keeps a snapshot of the pipeline it started with (`pipeline_name`,
  `pipeline_version`, `stages`) and of its directory's project, if any
  (`project`, `PipeMaestro.Projects.Project.snapshot/1`), so editing
  either never changes it. It
  is `queued` while it waits for room in its workspace (`max_running_tasks`),
  `running` while a stage runs, `awaiting_decision` when a person must say
  how to go on, and ends `succeeded`, `failed` or `canceled`.

  It may come from a GitHub issue (`issue_url`); with a pipeline that delivers
  (`PipeMaestro.Pipelines.Pipeline` `delivery`), its draft pull request
  is `pr_url`, and a decision waits in `pending_issue_comment` to be commented
  on the issue with the next stage.

  A task waiting for a decision has someone to decide (`decision_owner`, its
  creator unless passed on) and a deadline (`decision_due_at`).

  While it runs, a person may send instructions (`pending_instructions`, given
  to the next attempt or stage) or ask it to pause once the current stage ends
  (`pause_requested`).

  Its worktree (on the runner) stays after it ends, until a person asks to
  remove it: `worktree_removal_requested_at` until the runner confirms,
  then `worktree_removed_at`, or `worktree_error` if it could not.
  """
  use PipeMaestro.Schema

  import Ecto.Changeset

  alias PipeMaestro.Accounts.User
  alias PipeMaestro.Pipelines.{Pipeline, Stage}
  alias PipeMaestro.Runners.Runner
  alias PipeMaestro.Tasks.{Decision, StageRun}
  alias PipeMaestro.Workspaces.Workspace

  @type status :: :queued | :running | :awaiting_decision | :succeeded | :failed | :canceled

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          title: String.t() | nil,
          prompt: String.t() | nil,
          directory: String.t() | nil,
          git: boolean(),
          branch: String.t() | nil,
          worktree: String.t() | nil,
          worktree_removal_requested_at: DateTime.t() | nil,
          worktree_removed_at: DateTime.t() | nil,
          worktree_error: String.t() | nil,
          pending_instructions: String.t() | nil,
          decision_owner_id: Ecto.UUID.t() | nil,
          decision_owner: User.t() | Ecto.Association.NotLoaded.t() | nil,
          decision_due_at: DateTime.t() | nil,
          issue_url: String.t() | nil,
          pr_url: String.t() | nil,
          pending_issue_comment: String.t() | nil,
          pause_requested: boolean(),
          status: status(),
          current_stage: non_neg_integer(),
          decision_reason: String.t() | nil,
          finished_at: DateTime.t() | nil,
          pipeline_name: String.t() | nil,
          pipeline_version: pos_integer() | nil,
          stages: [Stage.t()],
          pipeline_id: Ecto.UUID.t() | nil,
          project_id: Ecto.UUID.t() | nil,
          project: map() | nil,
          pipeline_context: map() | nil,
          workspace_id: Ecto.UUID.t() | nil,
          runner_id: Ecto.UUID.t() | nil,
          runner: Runner.t() | Ecto.Association.NotLoaded.t() | nil,
          created_by_user_id: Ecto.UUID.t() | nil,
          created_by_user: User.t() | Ecto.Association.NotLoaded.t() | nil,
          stage_runs: [StageRun.t()] | Ecto.Association.NotLoaded.t(),
          decisions: [Decision.t()] | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "tasks" do
    field :title, :string
    field :prompt, :string
    field :directory, :string
    field :git, :boolean, default: false
    field :branch, :string
    field :worktree, :string
    field :worktree_removal_requested_at, :utc_datetime
    field :worktree_removed_at, :utc_datetime
    field :worktree_error, :string
    field :pending_instructions, :string
    field :decision_due_at, :utc_datetime
    field :issue_url, :string
    field :pr_url, :string
    field :pending_issue_comment, :string
    field :pause_requested, :boolean, default: false

    field :status, Ecto.Enum,
      values: [:queued, :running, :awaiting_decision, :succeeded, :failed, :canceled],
      default: :running

    field :current_stage, :integer, default: 0
    field :decision_reason, :string
    field :finished_at, :utc_datetime
    field :pipeline_name, :string
    field :pipeline_version, :integer
    field :project, :map
    field :pipeline_context, :map

    embeds_many :stages, Stage, on_replace: :delete

    belongs_to :pipeline, Pipeline
    # The project's own record; the task reads its `project` snapshot.
    field :project_id, :binary_id
    belongs_to :workspace, Workspace
    belongs_to :runner, Runner
    belongs_to :created_by_user, User
    belongs_to :decision_owner, User
    has_many :stage_runs, StageRun
    has_many :decisions, Decision

    timestamps()
  end

  @doc "Whether the task can still change: running or waiting for a decision."
  @spec active?(t()) :: boolean()
  def active?(%__MODULE__{status: status}),
    do: status in [:queued, :running, :awaiting_decision]

  @doc "The stage the task is at."
  @spec current(t()) :: Stage.t()
  def current(%__MODULE__{stages: stages, current_stage: index}), do: Enum.at(stages, index)

  @doc "Whether the task is at its last stage."
  @spec last_stage?(t()) :: boolean()
  def last_stage?(%__MODULE__{stages: stages, current_stage: index}),
    do: index == length(stages) - 1

  @doc "Changeset for a new task: what to do, with which pipeline, runner and directory."
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(task, attrs) do
    task
    |> cast(attrs, [:title, :prompt, :pipeline_id, :runner_id, :directory, :issue_url])
    |> validate_format(:issue_url, ~r{^https://github\.com/[\w.-]+/[\w.-]+/issues/\d+$},
      message: "use o link de uma issue do GitHub (https://github.com/dono/repo/issues/N)"
    )
    |> update_change(:title, &String.trim/1)
    |> validate_required([:title], message: "dê um título à tarefa")
    |> validate_required([:prompt], message: "descreva o que deve ser feito")
    |> validate_required([:pipeline_id], message: "escolha um pipeline")
    |> validate_required([:runner_id], message: "escolha um runner online")
    |> validate_required([:directory], message: "escolha um diretório do runner")
    |> validate_length(:title, max: 120)
    |> validate_length(:prompt, max: 16_000, count: :bytes)
  end
end
