defmodule PipeMaestro.Integrations.PrOutcome do
  @moduledoc """
  What became of the pull request a task delivered on a linked repository
  ([ADR 0053](docs/adr/0053-qualidade-das-entregas.md)), one per task, kept
  by `PipeMaestro.Integrations.PrOutcomes`:

  - `ready_at`: the first time the task succeeded with its pull request,
    never written again (a correction ends the task again later);
  - `state`: `"open"`, `"merged"` (`merged_at`) or `"closed"` without the
    merge (`closed_at`);
  - `review_rounds`: reviews asking for changes that became a correction by
    the pipeline, each counted once (`review_keys`), never reset;
  - `pipeline_shas` and `human_shas`: the pull request's commits the
    pipeline pushed and those someone else did, told apart by SHA;
    `observed_head` is the pipeline's last commit already taken into
    account;
  - `commits_tracked`: whether the platform may read the commits (a
    connection whose `api_mode` is `"control_plane"`); `commits_final`
    whether they were read after the merge or the close; `commits_error`
    the host's last failure, for the reconciliation to try again.

  How it is accepted is worked out from that (`classify/1`), never kept.
  """
  use PipeMaestro.Schema

  alias PipeMaestro.Integrations.LinkedRepo
  alias PipeMaestro.Tasks.Task

  @type state :: String.t()
  @type classification :: :accepted_clean | :accepted_changed | :closed | :open

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          task_id: Ecto.UUID.t() | nil,
          task: Task.t() | Ecto.Association.NotLoaded.t(),
          workspace_id: Ecto.UUID.t() | nil,
          linked_repo_id: Ecto.UUID.t() | nil,
          linked_repo: LinkedRepo.t() | Ecto.Association.NotLoaded.t() | nil,
          pr_number: pos_integer() | nil,
          pr_url: String.t() | nil,
          ready_at: DateTime.t() | nil,
          state: state(),
          merged_at: DateTime.t() | nil,
          closed_at: DateTime.t() | nil,
          review_rounds: non_neg_integer(),
          review_keys: [String.t()],
          pipeline_shas: [String.t()],
          human_shas: [String.t()],
          observed_head: String.t() | nil,
          commits_tracked: boolean(),
          commits_final: boolean(),
          commits_error: String.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "integration_pr_outcomes" do
    field :workspace_id, :binary_id
    field :pr_number, :integer
    field :pr_url, :string
    field :ready_at, :utc_datetime
    field :state, :string, default: "open"
    field :merged_at, :utc_datetime
    field :closed_at, :utc_datetime
    field :review_rounds, :integer, default: 0
    field :review_keys, {:array, :string}, default: []
    field :pipeline_shas, {:array, :string}, default: []
    field :human_shas, {:array, :string}, default: []
    field :observed_head, :string
    field :commits_tracked, :boolean, default: true
    field :commits_final, :boolean, default: false
    field :commits_error, :string

    belongs_to :task, Task
    belongs_to :linked_repo, LinkedRepo

    timestamps()
  end

  @doc """
  How the pull request was accepted: merged as the pipeline left it
  (`:accepted_clean`), merged with a person's commit or a correction a
  review asked for (`:accepted_changed`), `:closed` without the merge, or
  still `:open`.
  """
  @spec classify(t()) :: classification()
  def classify(%__MODULE__{state: "merged", human_shas: [], review_rounds: 0}),
    do: :accepted_clean

  def classify(%__MODULE__{state: "merged"}), do: :accepted_changed
  def classify(%__MODULE__{state: "closed"}), do: :closed
  def classify(%__MODULE__{}), do: :open
end
