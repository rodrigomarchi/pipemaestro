defmodule PipeMaestro.RunnerTelemetry.Event do
  @moduledoc """
  Something that happened to a runner apart from its jobs' work (ADR 0039):
  told by the runner in its log (an update, a dropped connection...) or
  seen by the control plane in what a job reported (a setup or a delivery
  that failed). `kinds/0` lists them, each in a `group/1` the screens filter
  by.
  """
  use PipeMaestro.Schema

  alias PipeMaestro.Runners.Runner

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          runner_id: Ecto.UUID.t() | nil,
          workspace_id: Ecto.UUID.t() | nil,
          at: DateTime.t() | nil,
          kind: String.t() | nil,
          level: String.t() | nil,
          message: String.t() | nil,
          attrs: map(),
          job_id: Ecto.UUID.t() | nil,
          task_id: Ecto.UUID.t() | nil
        }

  @groups %{
    "update_applied" => "update",
    "update_failed" => "update",
    "update_draining" => "update",
    "connection_lost" => "connection",
    "outbox_dropped" => "connection",
    "log_dropped" => "connection",
    "job_lost" => "connection",
    "setup_failed" => "setup",
    "delivery_failed" => "git",
    "credential_refused" => "git",
    "scratch_remove_failed" => "worktree",
    "worktree_remove_failed" => "worktree",
    "claude_sessions_not_found" => "worktree",
    "doctor_changed" => "doctor"
  }

  schema "runner_events" do
    belongs_to :runner, Runner
    field :workspace_id, :binary_id
    field :at, :utc_datetime_usec
    field :kind, :string
    field :level, :string
    field :message, :string
    field :attrs, :map, default: %{}
    field :job_id, :binary_id
    field :task_id, :binary_id
  end

  @doc "The kinds of event."
  @spec kinds() :: [String.t()]
  def kinds, do: Map.keys(@groups)

  @doc "The group a kind belongs to: update, connection, setup, git, worktree or doctor."
  @spec group(String.t()) :: String.t()
  def group(kind), do: Map.get(@groups, kind, "other")

  @doc "The kinds of a group."
  @spec kinds_of(String.t()) :: [String.t()]
  def kinds_of(group), do: for({kind, ^group} <- @groups, do: kind)
end
