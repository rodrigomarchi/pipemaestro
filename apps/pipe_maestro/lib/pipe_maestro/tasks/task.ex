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

  It may come from a task source (`PipeMaestro.TaskSources`): its origin is
  the `source`'s key, the item's id there (`source_id`), its link
  (`source_url`) and what the source keeps of it (`source_ref`); a decision
  leaves a note in `pending_source_note` for the source to deliver with the
  next stage. And from a task proposal
  (`proposal_job`, `PipeMaestro.Proposals.TaskKind`): one proposal becomes
  one task at most. With a pipeline that delivers
  (`PipeMaestro.Pipelines.Pipeline` `delivery`), its draft pull request
  is `pr_url`.

  The repository of a git host where the platform keeps that pull request is
  `linked_repo_id`, given by the source; what the platform already reflected
  on the host is in `issue_feedback` and the last commit pushed in
  `head_sha` (`PipeMaestro.Integrations`, which alone reads them).

  With a pipeline that merges its pull request (`auto_merge`), a task that
  succeeded has a `merge_state`: `"waiting_checks"` (since
  `merge_waiting_since`) until the host's checks end, `"fixing"` while a
  correction stage works on a check that failed or a conflict (`merge_fixes`
  counts them), `"merged"`, or `"blocked"` with the reason in
  `merge_reason` (`PipeMaestro.Integrations.AutoMerge`).

  A task waiting for a decision has someone to decide (`decision_owner`, its
  creator unless passed on) and a deadline (`decision_due_at`). When it
  paused because a stage blocked or failed, it may also have questions for
  the person (`decision_questionnaire`, `PipeMaestro.Tasks.Questionnaire`):
  the agent's own, or those of the analysis the platform asked for on a
  failure (`decision_analysis_job`, `PipeMaestro.Proposals.AnalysisKind`).

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
  alias PipeMaestro.Jobs.Job
  alias PipeMaestro.Pipelines.{Pipeline, Stage}
  alias PipeMaestro.Runners.Runner
  alias PipeMaestro.Tasks.{Decision, StageRun}
  alias PipeMaestro.TaskSources
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
          source: String.t() | nil,
          source_id: String.t() | nil,
          source_url: String.t() | nil,
          source_ref: map(),
          pending_source_note: String.t() | nil,
          pr_url: String.t() | nil,
          issue_feedback: map(),
          head_sha: String.t() | nil,
          linked_repo_id: Ecto.UUID.t() | nil,
          pause_requested: boolean(),
          merge_state: String.t() | nil,
          merge_fixes: non_neg_integer(),
          merge_reason: String.t() | nil,
          merge_waiting_since: DateTime.t() | nil,
          status: status(),
          current_stage: non_neg_integer(),
          decision_reason: String.t() | nil,
          decision_questionnaire: map() | nil,
          decision_analysis_job_id: Ecto.UUID.t() | nil,
          decision_analysis_job: Job.t() | Ecto.Association.NotLoaded.t() | nil,
          proposal_job_id: Ecto.UUID.t() | nil,
          proposal_job: Job.t() | Ecto.Association.NotLoaded.t() | nil,
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
    field :source, :string
    field :source_id, :string
    field :source_url, :string
    field :source_ref, :map, default: %{}
    field :pending_source_note, :string
    field :pr_url, :string
    field :issue_feedback, :map, default: %{}
    field :head_sha, :string
    field :pause_requested, :boolean, default: false
    field :merge_state, :string
    field :merge_fixes, :integer, default: 0
    field :merge_reason, :string
    field :merge_waiting_since, :utc_datetime

    field :status, Ecto.Enum,
      values: [:queued, :running, :awaiting_decision, :succeeded, :failed, :canceled],
      default: :running

    field :current_stage, :integer, default: 0
    field :decision_reason, :string
    field :decision_questionnaire, :map
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
    belongs_to :decision_analysis_job, Job
    belongs_to :proposal_job, Job
    # The git host's repository the source gave (`PipeMaestro.Integrations`).
    field :linked_repo_id, :binary_id
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
    |> cast(attrs, [:title, :prompt, :pipeline_id, :project_id, :source_url])
    |> put_linked_origin()
    |> update_change(:title, &(&1 && String.trim(&1)))
    |> validate_required([:title], message: "dê um título à tarefa")
    |> validate_required([:prompt], message: "descreva o que deve ser feito")
    |> validate_required([:pipeline_id], message: "escolha um pipeline")
    |> validate_required([:project_id], message: "escolha um projeto")
    |> validate_length(:title, max: 120)
    |> validate_length(:prompt, max: 16_000, count: :bytes)
    |> unique_constraint(:proposal_job_id, message: "esta proposta já virou uma tarefa")
  end

  # A link pasted on the task is an origin when a source recognizes it. A
  # task that already has its origin (from its source or its proposal) keeps it.
  defp put_linked_origin(%Ecto.Changeset{data: %{source: source}} = changeset)
       when is_binary(source),
       do: delete_change(changeset, :source_url)

  defp put_linked_origin(changeset) do
    case get_change(changeset, :source_url) do
      nil ->
        changeset

      url ->
        case TaskSources.parse_link(url) do
          {:ok, origin} ->
            change(changeset,
              source: origin.source,
              source_id: origin.external_id,
              source_url: origin.url,
              source_ref: origin.ref
            )

          {:error, message} ->
            add_error(changeset, :source_url, message)
        end
    end
  end
end
