defmodule PipeMaestro.Integrations.Delivery do
  @moduledoc """
  One event of a connection the platform took in: a webhook delivery, an
  issue the reconciliation found, or a delivery reprocessed by a person
  (`source`). It is recorded before it is processed, once per `external_id`
  (the host's delivery id), and its `status` says how processing ended
  (`docs/specs/integracoes.md`, section 4):

  - `"received"`: not processed yet;
  - `"processed"`: started a triage or a task, or applied a command;
  - `"ignored"`: nothing to do, the reason in `outcome`;
  - `"waiting_runner"`: no runner online; the reconciliation tries again;
  - `"failed"`: an error, in `outcome`; the reconciliation tries again.
  """
  use PipeMaestro.Schema

  alias PipeMaestro.Integrations.Connection

  @statuses ~w(received processed ignored waiting_runner failed)
  @sources ~w(webhook reconcile replay)
  # The payload kept for the screen and a replay.
  @payload_bytes 65_536

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          source: String.t() | nil,
          external_id: String.t() | nil,
          event: String.t() | nil,
          action: String.t() | nil,
          kind: String.t() | nil,
          repo_full_name: String.t() | nil,
          issue_number: integer() | nil,
          payload: map(),
          status: String.t(),
          outcome: String.t() | nil,
          task_id: Ecto.UUID.t() | nil,
          proposal_job_id: Ecto.UUID.t() | nil,
          attempts: non_neg_integer(),
          processed_at: DateTime.t() | nil,
          workspace_id: Ecto.UUID.t() | nil,
          connection_id: Ecto.UUID.t() | nil,
          connection: Connection.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @timestamps_opts [type: :utc_datetime_usec]
  schema "integration_deliveries" do
    field :source, :string
    field :external_id, :string
    field :event, :string
    field :action, :string
    field :kind, :string
    field :repo_full_name, :string
    field :issue_number, :integer
    field :payload, :map, default: %{}
    field :status, :string, default: "received"
    field :outcome, :string
    field :task_id, :binary_id
    field :proposal_job_id, :binary_id
    field :attempts, :integer, default: 0
    field :processed_at, :utc_datetime_usec
    field :workspace_id, :binary_id

    belongs_to :connection, Connection

    timestamps()
  end

  @doc "The statuses of a delivery."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc "Where a delivery came from."
  @spec sources() :: [String.t()]
  def sources, do: @sources

  @doc "The payload as kept: whole when small, otherwise only its top-level identity."
  @spec keep_payload(map()) :: map()
  def keep_payload(payload) when is_map(payload) do
    if byte_size(JSON.encode!(payload)) <= @payload_bytes,
      do: payload,
      else: Map.take(payload, ~w(action number repository sender)) |> Map.put("_cortado", true)
  end
end
