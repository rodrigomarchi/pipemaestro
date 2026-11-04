defmodule PipeMaestro.Proposals.Kind do
  @moduledoc """
  One kind of proposal (`PipeMaestro.Proposals`): what a person asks, the job
  that asks the agent, and how its answer becomes something to review.

  `changeset/2` validates the request and resolves `runner_id` and
  `directory` (a kind about a task takes them from the task). `job/3` builds
  the agent's job from the request; `previous` is the proposal a new round
  revises. `result/2` reads the agent's structured output.
  """

  alias PipeMaestro.Jobs.Job
  alias PipeMaestro.Workspaces.Workspace

  @typedoc "The job a request becomes."
  @type job_spec :: %{
          required(:title) => String.t(),
          required(:prompt) => String.t(),
          required(:system_prompt) => String.t(),
          required(:output_schema) => map(),
          required(:scratch) => boolean(),
          required(:timeout_ms) => pos_integer()
        }

  @doc "The kind's name, as it is stored and routed (`\"task\"`)."
  @callback name() :: String.t()

  @doc "What the kind is called on screen."
  @callback label() :: String.t()

  @doc "The Heroicon that stands for it."
  @callback icon() :: String.t()

  @doc "Validates a request in `workspace`; the changes carry `runner_id` and `directory`."
  @callback changeset(map(), Workspace.t()) :: Ecto.Changeset.t()

  @doc "The job for a valid request (`input`), revising `previous` when given."
  @callback job(map(), Workspace.t(), Job.t() | nil) :: job_spec()

  @doc "What a finished proposal says, read from its structured output."
  @callback result(map(), Job.t()) :: {:ok, map()} | {:error, String.t()}
end
