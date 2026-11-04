defmodule PipeMaestro.Jobs.Event do
  @moduledoc """
  One event of a job's run, numbered by the runner (`seq`, from 1). The pair
  `(job_id, seq)` is unique, so a resent event is stored once.
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
