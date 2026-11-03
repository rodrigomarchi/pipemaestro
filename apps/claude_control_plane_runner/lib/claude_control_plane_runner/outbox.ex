defmodule ClaudeControlPlaneRunner.Outbox do
  @moduledoc """
  What the runner told the control plane and the control plane has not yet
  confirmed (the channel's reply to each push). The connection keeps every
  job message here until its reply arrives and sends what is left again after
  reconnecting, in order; the control plane ignores what it already has (an
  event by its `seq`, a start or an end of a job that already started or
  ended).

  It lives in memory: a runner that restarts loses it, and the control plane
  fails the jobs that were running then (`Hello.running_job_ids`).

  It holds at most `max` messages. Past that, the oldest `job:event`s go
  first: a job's start and end are what moves the task along, and are never
  dropped.
  """

  @default_max 20_000

  @opaque t :: %{
            max: pos_integer(),
            next: non_neg_integer(),
            entries: :gb_trees.tree(non_neg_integer(), {String.t(), map()}),
            refs: %{optional(term()) => non_neg_integer()}
          }

  @doc "An empty outbox holding up to `max` messages."
  @spec new(pos_integer()) :: t()
  def new(max \\ @default_max), do: %{max: max, next: 0, entries: :gb_trees.empty(), refs: %{}}

  @doc "Adds a message; returns its id, to mark it `sent/3`."
  @spec add(t(), String.t(), map()) :: {non_neg_integer(), t()}
  def add(outbox, event, payload) do
    id = outbox.next
    entries = :gb_trees.insert(id, {event, payload}, outbox.entries)
    {id, trim(%{outbox | next: id + 1, entries: entries})}
  end

  @doc "The message `id` was pushed and `ref` will carry its reply."
  @spec sent(t(), non_neg_integer(), term()) :: t()
  def sent(outbox, id, ref), do: %{outbox | refs: Map.put(outbox.refs, ref, id)}

  @doc "The reply to `ref` arrived: its message is done."
  @spec confirmed(t(), term()) :: t()
  def confirmed(outbox, ref) do
    case Map.pop(outbox.refs, ref) do
      {nil, _refs} -> outbox
      {id, refs} -> %{outbox | refs: refs, entries: :gb_trees.delete_any(id, outbox.entries)}
    end
  end

  @doc "The connection dropped: no reply to an earlier push will come."
  @spec forget_refs(t()) :: t()
  def forget_refs(outbox), do: %{outbox | refs: %{}}

  @doc "The messages still to confirm, oldest first, as `{id, event, payload}`."
  @spec pending(t()) :: [{non_neg_integer(), String.t(), map()}]
  def pending(outbox) do
    for {id, {event, payload}} <- :gb_trees.to_list(outbox.entries), do: {id, event, payload}
  end

  @doc "The jobs with messages still to confirm."
  @spec job_ids(t()) :: [String.t()]
  def job_ids(outbox) do
    outbox
    |> pending()
    |> Enum.map(fn {_id, _event, payload} -> payload["job_id"] end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp trim(outbox) do
    if :gb_trees.size(outbox.entries) > outbox.max,
      do: drop_oldest_event(outbox),
      else: outbox
  end

  defp drop_oldest_event(outbox) do
    case Enum.find(pending(outbox), fn {_id, event, _payload} -> event == "job:event" end) do
      nil -> outbox
      {id, _event, _payload} -> trim(%{outbox | entries: :gb_trees.delete(id, outbox.entries)})
    end
  end
end
