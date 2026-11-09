defmodule PipeMaestro.TaskSources.Item do
  @moduledoc """
  An item read on a task source, normalized whatever the source (ADR 0053):
  its `title`, `description`, `author`, `labels`, `priority` (`nil` when the
  source has none) and link (`url`), with the `source`, the item's id there
  (`external_id`) and what the source keeps of it (`ref`).

  `kind` names the item as the source does (`"Issue"`), for the request and
  the title of a task made of it. `linked_repo_id` is the repository of a git
  host where the platform keeps the task's pull request, when the source
  knows one (`PipeMaestro.Integrations.keeps_pull_request?/1`).
  """

  alias PipeMaestro.TaskSources.Origin

  @enforce_keys [:source, :external_id, :url, :kind]
  defstruct [
    :source,
    :external_id,
    :url,
    :title,
    :description,
    :author,
    :priority,
    :kind,
    :linked_repo_id,
    labels: [],
    ref: %{}
  ]

  @type t :: %__MODULE__{
          source: String.t(),
          external_id: String.t(),
          url: String.t() | nil,
          title: String.t() | nil,
          description: String.t() | nil,
          author: String.t() | nil,
          priority: String.t() | nil,
          kind: String.t(),
          linked_repo_id: Ecto.UUID.t() | nil,
          labels: [String.t()],
          ref: map()
        }

  @doc "The origin a task or a triage of `item` keeps."
  @spec origin(t()) :: Origin.t()
  def origin(%__MODULE__{} = item) do
    %Origin{
      source: item.source,
      external_id: item.external_id,
      url: item.url,
      ref: item.ref,
      linked_repo_id: item.linked_repo_id
    }
  end
end
