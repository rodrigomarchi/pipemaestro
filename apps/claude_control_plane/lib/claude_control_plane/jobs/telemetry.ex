defmodule ClaudeControlPlane.Jobs.Telemetry do
  @moduledoc """
  One record of a job's OpenTelemetry, as the runner relayed it
  (`ClaudeControlPlaneProtocol.Telemetry`): an event of the agent CLI (a call
  to the model API, a tool that ran, a permission decided...) or a metric's
  increment (`"metric:<name>"`, its value in `attrs["value"]`).

  Some metrics add up on the job (`ClaudeControlPlane.Jobs.Job`
  `telemetry_totals`): `increments/1` says by how much.
  """
  use ClaudeControlPlane.Schema

  alias ClaudeControlPlane.Jobs.Job

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          name: String.t() | nil,
          at: DateTime.t() | nil,
          attrs: map(),
          job_id: Ecto.UUID.t() | nil,
          workspace_id: Ecto.UUID.t() | nil,
          inserted_at: DateTime.t() | nil
        }

  # The metrics worth a total on the job, by the key they add to (`nil`: any
  # `type`).
  @totals %{
    {"metric:lines_of_code", "added"} => "lines_added",
    {"metric:lines_of_code", "removed"} => "lines_removed",
    {"metric:commit", nil} => "commits",
    {"metric:pull_request", nil} => "pull_requests",
    {"metric:active_time", nil} => "active_seconds"
  }

  schema "job_telemetry" do
    field :name, :string
    field :at, :utc_datetime_usec
    field :attrs, :map, default: %{}
    field :workspace_id, :binary_id
    belongs_to :job, Job
    field :inserted_at, :utc_datetime_usec
  end

  @doc """
  What `records` (`%{name, attrs}`) add to a job's totals, by key:
  `%{"lines_added" => 7}`.
  """
  @spec increments([%{name: String.t(), attrs: map()}]) :: %{String.t() => number()}
  def increments(records) do
    for %{name: name, attrs: attrs} <- records,
        key = @totals[{name, attrs["type"]}] || @totals[{name, nil}],
        is_number(attrs["value"]),
        reduce: %{} do
      acc -> Map.update(acc, key, attrs["value"], &(&1 + attrs["value"]))
    end
  end
end
