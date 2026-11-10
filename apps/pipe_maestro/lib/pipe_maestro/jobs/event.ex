defmodule PipeMaestro.Jobs.Event do
  @moduledoc """
  One event of a job's run, numbered by the runner (`seq`, from 1). The pair
  `(job_id, seq)` is unique, so a resent event is stored once.

  Past its workspace's retention, an event may keep only its metadata
  (`metadata_only/1`): its type, the tool and call it names, durations,
  tokens, cost and errors, never what the agent read, wrote or said.
  """
  use PipeMaestro.Schema

  import Ecto.Changeset

  alias PipeMaestro.Jobs.Job
  alias PipeMaestroProtocol.JobEvent

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          seq: pos_integer() | nil,
          type: String.t() | nil,
          data: map(),
          job_id: Ecto.UUID.t() | nil,
          inserted_at: DateTime.t() | nil
        }

  schema "job_events" do
    field :seq, :integer
    field :type, :string
    field :data, :map, default: %{}

    belongs_to :job, Job

    timestamps(updated_at: false)
  end

  # What an event keeps once the retention takes its content: identifiers,
  # numbers and outcomes, never text nor arguments.
  @metadata_keys ~w(
    name tool_name id tool_use_id parent_tool_use_id
    duration_ms duration_api_ms ttft_ms delay_ms
    usage model_usage cost_usd
    is_error error status subtype stop_reason terminal_reason
    model num_turns pre_tokens attempt max_retries
  )

  @doc "The keys of `data` an event keeps once only its metadata stays."
  @spec metadata_keys() :: [String.t()]
  def metadata_keys, do: @metadata_keys

  @doc "An event's `data` with only its metadata (`metadata_keys/0`)."
  @spec metadata_only(map()) :: map()
  def metadata_only(data) when is_map(data), do: Map.take(data, @metadata_keys)

  @doc "Changeset for an event as the runner sent it."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(event, attrs) do
    event
    |> cast(attrs, [:seq, :type, :data])
    |> validate_required([:seq, :type])
    |> validate_number(:seq, greater_than: 0)
    |> validate_inclusion(:type, JobEvent.types())
  end
end
