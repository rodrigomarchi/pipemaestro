defmodule PipeMaestro.Jobs.ToolStat do
  @moduledoc """
  How one tool was used in a job's run (`PipeMaestro.Insights.store_summary/1`):
  `calls`, the calls that failed (`errors`) and that were refused (`denied`),
  and the time of the calls the OpenTelemetry measured (`total_ms` over
  `measured` calls). One row per tool, kept past the retention of the run's
  events, so tools add up across jobs and periods.
  """
  use PipeMaestro.Schema

  alias PipeMaestro.Jobs.Job

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          name: String.t() | nil,
          calls: non_neg_integer(),
          errors: non_neg_integer(),
          denied: non_neg_integer(),
          total_ms: non_neg_integer(),
          measured: non_neg_integer(),
          job_id: Ecto.UUID.t() | nil,
          workspace_id: Ecto.UUID.t() | nil
        }

  schema "job_tool_stats" do
    field :name, :string
    field :calls, :integer, default: 0
    field :errors, :integer, default: 0
    field :denied, :integer, default: 0
    field :total_ms, :integer, default: 0
    field :measured, :integer, default: 0
    field :workspace_id, :binary_id
    belongs_to :job, Job
  end
end
