defmodule PipeMaestro.RunnerTelemetry.HealthSample do
  @moduledoc """
  One sample of how a runner's machine was doing, as the runner reported it
  (`PipeMaestroProtocol.RunnerHealth`). Any measure may be missing (`nil`):
  the machine did not tell.
  """
  use PipeMaestro.Schema

  alias PipeMaestro.Runners.Runner

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          runner_id: Ecto.UUID.t() | nil,
          workspace_id: Ecto.UUID.t() | nil,
          at: DateTime.t() | nil,
          cpu_pct: float() | nil,
          load1: float() | nil,
          mem_used_bytes: non_neg_integer() | nil,
          mem_total_bytes: non_neg_integer() | nil,
          disk_free_bytes: non_neg_integer() | nil,
          disk_total_bytes: non_neg_integer() | nil,
          outbox_pending: non_neg_integer() | nil,
          running_jobs: non_neg_integer() | nil,
          beam_bytes: non_neg_integer() | nil
        }

  schema "runner_health_samples" do
    belongs_to :runner, Runner
    field :workspace_id, :binary_id
    field :at, :utc_datetime_usec
    field :cpu_pct, :float
    field :load1, :float
    field :mem_used_bytes, :integer
    field :mem_total_bytes, :integer
    field :disk_free_bytes, :integer
    field :disk_total_bytes, :integer
    field :outbox_pending, :integer
    field :running_jobs, :integer
    field :beam_bytes, :integer
  end

  @doc "The share of memory in use, from 0 to 1, or `nil`."
  @spec mem_share(t()) :: float() | nil
  def mem_share(%__MODULE__{mem_used_bytes: used, mem_total_bytes: total})
      when is_integer(used) and is_integer(total) and total > 0,
      do: used / total

  def mem_share(_sample), do: nil

  @doc "The share of the disk still free, from 0 to 1, or `nil`."
  @spec disk_free_share(t()) :: float() | nil
  def disk_free_share(%__MODULE__{disk_free_bytes: free, disk_total_bytes: total})
      when is_integer(free) and is_integer(total) and total > 0,
      do: free / total

  def disk_free_share(_sample), do: nil
end
