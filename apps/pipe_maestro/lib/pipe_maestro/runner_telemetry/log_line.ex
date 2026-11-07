defmodule PipeMaestro.RunnerTelemetry.LogLine do
  @moduledoc """
  One line of a runner's own log, as the runner sent it
  (`PipeMaestroProtocol.RunnerLog`): its secrets were redacted on the
  runner. Kept for the workspace's `runner_log_retention_days`.
  """
  use PipeMaestro.Schema

  alias PipeMaestro.Runners.Runner

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          runner_id: Ecto.UUID.t() | nil,
          workspace_id: Ecto.UUID.t() | nil,
          at: DateTime.t() | nil,
          level: String.t() | nil,
          message: String.t() | nil,
          event: String.t() | nil
        }

  schema "runner_log_lines" do
    belongs_to :runner, Runner
    field :workspace_id, :binary_id
    field :at, :utc_datetime_usec
    field :level, :string
    field :message, :string
    field :event, :string
  end
end
