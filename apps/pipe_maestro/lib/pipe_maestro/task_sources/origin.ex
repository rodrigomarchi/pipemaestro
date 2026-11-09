defmodule PipeMaestro.TaskSources.Origin do
  @moduledoc """
  Where a task or a triage came from (ADR 0053): the `source`'s key, the
  item's id there (`external_id`), its link (`url`), what the source keeps of
  it (`ref`, opaque to the task engine) and the repository of a git host the
  source knows (`linked_repo_id`, `PipeMaestro.TaskSources.Item`).

  A task keeps it in its `source*` fields and `linked_repo_id`; a triage, in
  its proposal's input under `"origin"` (`to_input/1`, `from_input/1`).
  """

  @enforce_keys [:source, :external_id]
  defstruct [:source, :external_id, :url, :linked_repo_id, ref: %{}]

  @type t :: %__MODULE__{
          source: String.t(),
          external_id: String.t(),
          url: String.t() | nil,
          linked_repo_id: Ecto.UUID.t() | nil,
          ref: map()
        }

  @doc "The origin as a proposal's input keeps it (`\"origin\"`)."
  @spec to_input(t()) :: map()
  def to_input(%__MODULE__{} = origin) do
    %{
      "source" => origin.source,
      "external_id" => origin.external_id,
      "url" => origin.url,
      "ref" => origin.ref,
      "linked_repo_id" => origin.linked_repo_id
    }
  end

  @doc """
  The origin in a proposal's input, if any. A triage of an issue saved before
  the sources kept `issue_url` (and, of a linked repository,
  `linked_repo_id` and `issue_number`): it is an issue of a git host.
  """
  @spec from_input(map() | nil) :: t() | nil
  def from_input(%{"origin" => %{"source" => source, "external_id" => id} = origin})
      when is_binary(source) and is_binary(id) do
    %__MODULE__{
      source: source,
      external_id: id,
      url: origin["url"],
      ref: origin["ref"] || %{},
      linked_repo_id: origin["linked_repo_id"]
    }
  end

  def from_input(%{"issue_url" => url} = input) when is_binary(url) do
    %__MODULE__{
      source: "git_issue",
      external_id: url,
      url: url,
      ref: if(input["issue_number"], do: %{"number" => input["issue_number"]}, else: %{}),
      linked_repo_id: input["linked_repo_id"]
    }
  end

  def from_input(_input), do: nil
end
