defmodule PipeMaestro.Notifications.Execution do
  @moduledoc """
  Something under way in a workspace, as the notification center shows it: a
  task running, waiting for a decision or in line, or a proposal being
  written (`PipeMaestro.Notifications.active_executions/2`). Derived from
  the tasks and jobs, never stored.

  `stage` counts from one (`stage` of `stage_count`); a proposal has no
  stages and says its `proposal_kind` instead.
  """

  @enforce_keys [:id, :type, :title, :status]
  defstruct [
    :id,
    :type,
    :title,
    :status,
    :stage,
    :stage_count,
    :runner_name,
    :started_at,
    :creator_id,
    :creator_name,
    :proposal_kind
  ]

  @type status :: :running | :awaiting_decision | :queued

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          type: :task | :proposal,
          title: String.t(),
          status: status(),
          stage: pos_integer() | nil,
          stage_count: non_neg_integer() | nil,
          runner_name: String.t() | nil,
          started_at: DateTime.t() | nil,
          creator_id: Ecto.UUID.t() | nil,
          creator_name: String.t() | nil,
          proposal_kind: String.t() | nil
        }
end
