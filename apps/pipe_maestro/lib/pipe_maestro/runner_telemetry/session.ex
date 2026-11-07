defmodule PipeMaestro.RunnerTelemetry.Session do
  @moduledoc """
  One connection of a runner: from the join the control plane accepted to
  the moment it ended, and why (`reasons/0`). A refused join is a session
  that ends as it starts, with the refusal as its reason.
  """
  use PipeMaestro.Schema

  alias PipeMaestro.Runners.Runner

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          runner_id: Ecto.UUID.t() | nil,
          workspace_id: Ecto.UUID.t() | nil,
          started_at: DateTime.t() | nil,
          ended_at: DateTime.t() | nil,
          end_reason: String.t() | nil,
          runner_version: String.t() | nil
        }

  @reasons ~w(closed revoked crashed reconnected restart outdated invalid_hello)

  @refusals ~w(outdated invalid_hello)

  schema "runner_sessions" do
    belongs_to :runner, Runner
    field :workspace_id, :binary_id
    field :started_at, :utc_datetime_usec
    field :ended_at, :utc_datetime_usec
    field :end_reason, :string
    field :runner_version, :string
  end

  @doc """
  Why a session ends:

    * `closed` — the connection ended (the runner stopped or the network
      dropped);
    * `revoked` — the runner was revoked;
    * `crashed` — the channel ended with an error;
    * `reconnected` — a new join found it still open;
    * `restart` — the control plane restarted while it was open;
    * `outdated`, `invalid_hello` — the join was refused (`refusals/0`).
  """
  @spec reasons() :: [String.t()]
  def reasons, do: @reasons

  @doc "The reasons of a refused join."
  @spec refusals() :: [String.t()]
  def refusals, do: @refusals

  @doc "Whether the session is a refused join."
  @spec refused?(t()) :: boolean()
  def refused?(%__MODULE__{end_reason: reason}), do: reason in @refusals
end
