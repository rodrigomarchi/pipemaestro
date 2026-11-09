defmodule PipeMaestro.Jobs.Job do
  @moduledoc """
  A prompt a workspace member sent to one of the workspace's runners, and how
  its run went: `queued` until the runner starts it, `running`, then
  `succeeded`, `failed` or `canceled`.

  A job is either sent on its own, in a disposable worktree of its project's
  directory, or runs one attempt of a task's stage (`stage_run`), or asks
  the agent for a proposal. `project` is the project it ran for, when there
  is one. `context` holds what the runner needs besides the prompt, in
  the wire form of `PipeMaestroProtocol.Job` (directory, worktree,
  output schema, model, budget, artifact path); `structured_output`,
  `artifact`, `workdir`, `setup` (how it prepared a new worktree) and
  `changes` (what the stage changed in the worktree) and `gates` (the stage's
  gate commands and how each went) are what the runner reported back, with
  `files_failed`, how many of the files the agent left in `CP_FILES_DIR` did
  not reach the platform (the ones that did are `PipeMaestro.Jobs.JobFile`).

  For auditing how the agent worked, the job also keeps what its run reported
  about itself: the CLI's `session_id` (and, for a job that asked to resume
  the previous stage's session, `session_resumed`: whether it did or started
  from scratch) and `cli_version`, the `model`, how it
  stopped (`stop_reason`, `result_subtype`), its times (`duration_api_ms`,
  `ttft_ms`, `wall_ms` timed by the runner), its tokens (fresh input, cache
  read and written, output, thinking), `model_usage` (tokens and cost per
  model), `permission_denials`, `subagents`, `environment` (the tools, MCP
  servers, agents, skills and plugins it had), the end of its `stderr` and
  `telemetry_totals` (the OpenTelemetry metrics summed: `lines_added`,
  `lines_removed`, `commits`, `pull_requests`, `active_seconds`). The
  OpenTelemetry records themselves are `PipeMaestro.Jobs.Telemetry`.

  `insights` is the run's summary (`PipeMaestro.Insights.summarize/1`), kept
  once the run ends: it outlives the events and records it comes from, which
  `PipeMaestro.Maintenance` removes after a while.
  """
  use PipeMaestro.Schema

  import Ecto.Changeset

  alias PipeMaestro.Accounts.User
  alias PipeMaestro.Jobs.Event
  alias PipeMaestro.Projects.Project
  alias PipeMaestro.Runners.Runner
  alias PipeMaestro.Workspaces.Workspace
  alias PipeMaestroProtocol.Job, as: WireJob

  @type status :: :queued | :running | :succeeded | :failed | :canceled

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          prompt: String.t() | nil,
          status: status(),
          exit_code: integer() | nil,
          result: String.t() | nil,
          error: String.t() | nil,
          cost_usd: Decimal.t() | nil,
          duration_ms: non_neg_integer() | nil,
          num_turns: non_neg_integer() | nil,
          started_at: DateTime.t() | nil,
          finished_at: DateTime.t() | nil,
          cancel_requested_at: DateTime.t() | nil,
          context: map(),
          structured_output: map() | nil,
          artifact: String.t() | nil,
          workdir: String.t() | nil,
          setup: map() | nil,
          changes: map() | nil,
          gates: [map()] | nil,
          delivery: map() | nil,
          files_failed: non_neg_integer() | nil,
          session_id: String.t() | nil,
          session_resumed: boolean() | nil,
          cli_version: String.t() | nil,
          model: String.t() | nil,
          stop_reason: String.t() | nil,
          result_subtype: String.t() | nil,
          duration_api_ms: non_neg_integer() | nil,
          ttft_ms: non_neg_integer() | nil,
          wall_ms: non_neg_integer() | nil,
          input_tokens: non_neg_integer() | nil,
          output_tokens: non_neg_integer() | nil,
          cache_read_tokens: non_neg_integer() | nil,
          cache_creation_tokens: non_neg_integer() | nil,
          thinking_tokens: non_neg_integer() | nil,
          model_usage: map() | nil,
          session_totals: map() | nil,
          permission_denials: [map()] | nil,
          subagents: map() | nil,
          environment: map() | nil,
          stderr: String.t() | nil,
          telemetry_totals: map(),
          insights: map() | nil,
          stage_run_id: Ecto.UUID.t() | nil,
          workspace_id: Ecto.UUID.t() | nil,
          workspace: Workspace.t() | Ecto.Association.NotLoaded.t(),
          runner_id: Ecto.UUID.t() | nil,
          runner: Runner.t() | Ecto.Association.NotLoaded.t() | nil,
          project_id: Ecto.UUID.t() | nil,
          project: Project.t() | Ecto.Association.NotLoaded.t() | nil,
          created_by_user_id: Ecto.UUID.t() | nil,
          created_by_user: User.t() | Ecto.Association.NotLoaded.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @finished [:succeeded, :failed, :canceled]

  schema "jobs" do
    field :prompt, :string
    field :status, Ecto.Enum, values: [:queued, :running | @finished], default: :queued
    field :exit_code, :integer
    field :result, :string
    field :error, :string
    field :cost_usd, :decimal
    field :duration_ms, :integer
    field :num_turns, :integer
    field :started_at, :utc_datetime
    field :finished_at, :utc_datetime
    field :cancel_requested_at, :utc_datetime
    field :context, :map, default: %{}
    field :structured_output, :map
    field :artifact, :string
    field :workdir, :string
    field :setup, :map
    field :changes, :map
    field :gates, {:array, :map}
    field :delivery, :map
    field :files_failed, :integer
    field :session_id, :string
    field :session_resumed, :boolean
    field :cli_version, :string
    field :model, :string
    field :stop_reason, :string
    field :result_subtype, :string
    field :duration_api_ms, :integer
    field :ttft_ms, :integer
    field :wall_ms, :integer
    field :input_tokens, :integer
    field :output_tokens, :integer
    field :cache_read_tokens, :integer
    field :cache_creation_tokens, :integer
    field :thinking_tokens, :integer
    field :model_usage, :map
    field :session_totals, :map
    field :permission_denials, {:array, :map}
    field :subagents, :map
    field :environment, :map
    field :stderr, :string
    field :telemetry_totals, :map, default: %{}
    field :insights, :map

    belongs_to :workspace, Workspace
    belongs_to :runner, Runner
    belongs_to :project, Project
    belongs_to :created_by_user, User
    belongs_to :stage_run, PipeMaestro.Tasks.StageRun
    has_many :events, Event

    timestamps()
  end

  @doc "The statuses a job ends in."
  @spec finished_statuses() :: [status()]
  def finished_statuses, do: @finished

  @doc "Whether the job is still waiting or running."
  @spec active?(t()) :: boolean()
  def active?(%__MODULE__{status: status}), do: status in [:queued, :running]

  @doc "Everything the model read in the run (fresh, from the cache, written to it) and wrote."
  @spec tokens(t()) :: non_neg_integer()
  def tokens(%__MODULE__{} = job) do
    [job.input_tokens, job.cache_read_tokens, job.cache_creation_tokens, job.output_tokens]
    |> Enum.map(&(&1 || 0))
    |> Enum.sum()
  end

  @doc "The share of the run's input read from the cache (`cache_hit/3`)."
  @spec cache_hit(t()) :: float() | nil
  def cache_hit(%__MODULE__{} = job),
    do: cache_hit(job.input_tokens, job.cache_read_tokens, job.cache_creation_tokens)

  @doc """
  The share of an input read from the cache, from 0 to 1 with two decimals;
  `nil` when there was no input.
  """
  @spec cache_hit(integer() | nil, integer() | nil, integer() | nil) :: float() | nil
  def cache_hit(fresh, cache_read, cache_creation) do
    total = (fresh || 0) + (cache_read || 0) + (cache_creation || 0)
    if total > 0, do: Float.round((cache_read || 0) / total, 2)
  end

  @doc "Changeset for a new job a person sends: the prompt and the project it runs for."
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(job, attrs) do
    job
    |> cast(attrs, [:prompt, :project_id])
    |> validate_required([:prompt], message: "escreva o que o agente deve fazer")
    |> validate_required([:project_id], message: "escolha um projeto")
    |> validate_length(:prompt, max: WireJob.max_prompt_bytes(), count: :bytes)
  end

  @doc """
  Changeset for a job the control plane builds itself (a proposal): the
  prompt, the runner and the project it is about, if any.
  """
  @spec runner_changeset(t(), map()) :: Ecto.Changeset.t()
  def runner_changeset(job, attrs) do
    job
    |> cast(attrs, [:prompt, :runner_id, :project_id])
    |> validate_required([:prompt], message: "escreva o que o agente deve fazer")
    |> validate_required([:runner_id], message: "escolha um runner online")
    |> validate_length(:prompt, max: WireJob.max_prompt_bytes(), count: :bytes)
  end

  @doc "Changeset for how the run ended, as the runner reported it."
  @spec finish_changeset(t(), map(), DateTime.t()) :: Ecto.Changeset.t()
  def finish_changeset(job, attrs, now) do
    job
    |> cast(with_tokens(attrs), [
      :status,
      :exit_code,
      :result,
      :error,
      :cost_usd,
      :duration_ms,
      :num_turns,
      :structured_output,
      :artifact,
      :workdir,
      :setup,
      :changes,
      :gates,
      :delivery,
      :files_failed,
      :session_id,
      :session_resumed,
      :cli_version,
      :model,
      :stop_reason,
      :result_subtype,
      :duration_api_ms,
      :ttft_ms,
      :wall_ms,
      :input_tokens,
      :output_tokens,
      :cache_read_tokens,
      :cache_creation_tokens,
      :thinking_tokens,
      :model_usage,
      :session_totals,
      :permission_denials,
      :subagents,
      :environment,
      :stderr
    ])
    |> validate_required([:status])
    |> validate_inclusion(:status, @finished)
    |> validate_number(:duration_ms, greater_than_or_equal_to: 0)
    |> validate_number(:num_turns, greater_than_or_equal_to: 0)
    |> validate_number(:files_failed, greater_than_or_equal_to: 0)
    |> put_change(:finished_at, now)
  end

  # The run's `usage` (`PipeMaestroProtocol.Job`) becomes the token
  # columns, which reports sum.
  defp with_tokens(%{"usage" => %{} = usage} = attrs) do
    Map.merge(attrs, %{
      "input_tokens" => usage["fresh_input"],
      "output_tokens" => usage["output"],
      "cache_read_tokens" => usage["cache_read"],
      "cache_creation_tokens" => usage["cache_creation"],
      "thinking_tokens" => usage["thinking"]
    })
  end

  defp with_tokens(attrs), do: attrs
end
