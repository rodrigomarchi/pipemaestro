defmodule ClaudeControlPlane.Jobs.Job do
  @moduledoc """
  A prompt a workspace member sent to one of the workspace's runners, and how
  its run went: `queued` until the runner starts it, `running`, then
  `succeeded`, `failed` or `canceled`.
  """
  use ClaudeControlPlane.Schema

  import Ecto.Changeset

  alias ClaudeControlPlane.Accounts.User
  alias ClaudeControlPlane.Jobs.Event
  alias ClaudeControlPlane.Runners.Runner
  alias ClaudeControlPlane.Workspaces.Workspace
  alias ClaudeControlPlaneProtocol.Job, as: WireJob

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
          workspace_id: Ecto.UUID.t() | nil,
          workspace: Workspace.t() | Ecto.Association.NotLoaded.t(),
          runner_id: Ecto.UUID.t() | nil,
          runner: Runner.t() | Ecto.Association.NotLoaded.t() | nil,
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

    belongs_to :workspace, Workspace
    belongs_to :runner, Runner
    belongs_to :created_by_user, User
    has_many :events, Event

    timestamps()
  end

  @doc "The statuses a job ends in."
  @spec finished_statuses() :: [status()]
  def finished_statuses, do: @finished

  @doc "Whether the job is still waiting or running."
  @spec active?(t()) :: boolean()
  def active?(%__MODULE__{status: status}), do: status in [:queued, :running]

  @doc "Changeset for a new job: the prompt and the runner chosen for it."
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(job, attrs) do
    job
    |> cast(attrs, [:prompt, :runner_id])
    |> validate_required([:prompt], message: "escreva o que o agente deve fazer")
    |> validate_required([:runner_id], message: "escolha um runner online")
    |> validate_length(:prompt, max: WireJob.max_prompt_bytes(), count: :bytes)
  end

  @doc "Changeset for how the run ended, as the runner reported it."
  @spec finish_changeset(t(), map(), DateTime.t()) :: Ecto.Changeset.t()
  def finish_changeset(job, attrs, now) do
    job
    |> cast(attrs, [:status, :exit_code, :result, :error, :cost_usd, :duration_ms, :num_turns])
    |> validate_required([:status])
    |> validate_inclusion(:status, @finished)
    |> validate_number(:duration_ms, greater_than_or_equal_to: 0)
    |> validate_number(:num_turns, greater_than_or_equal_to: 0)
    |> put_change(:finished_at, now)
  end
end
