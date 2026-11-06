defmodule PipeMaestro.Integrations.IssueState do
  @moduledoc """
  What the platform last saw of an issue of a linked repository:

  - `labels`: its labels then, to tell the one just added (Forgejo sends the
    whole list on every change);
  - `fired`: the triggers that already fired on it, by trigger id
    (`%{"at", "task_id" | "proposal_job_id"}`), so neither a repeated
    delivery nor the reconciliation fires twice;
  - `commands`: the comments already applied as commands, by id.
  """
  use PipeMaestro.Schema

  alias PipeMaestro.Integrations.LinkedRepo

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          number: pos_integer() | nil,
          labels: [String.t()],
          seen_updated_at: DateTime.t() | nil,
          fired: map(),
          commands: [String.t()],
          repo_id: Ecto.UUID.t() | nil,
          repo: LinkedRepo.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "integration_issues" do
    field :number, :integer
    field :labels, {:array, :string}, default: []
    field :seen_updated_at, :utc_datetime
    field :fired, :map, default: %{}
    field :commands, {:array, :string}, default: []

    belongs_to :repo, LinkedRepo

    timestamps()
  end
end
