defmodule PipeMaestroRunner.Outbox do
  @moduledoc """
  What the runner told the control plane and the control plane has not yet
  confirmed (the channel's reply to each push). The connection keeps every
  job message here until its reply arrives and sends what is left again after
  reconnecting, in order; the control plane ignores what it already has (an
  event by its `seq`, a start or an end of a job that already started or
  ended).

  Given a file, the messages that move a task along (a job's end, a removed
  worktree) are also kept there, so they survive a restart of the runner: the
  runner starts with them, still counts their jobs as running, and sends them
  again. A job's events live only in memory, except before an update
  (`persist_all/1`), which keeps everything still to confirm.

  It holds at most `max` messages. Past that, the oldest of a job's events
  and telemetry and of the runner's log go first (`dropped/1` counts them): a
  job's start and end are what moves the task along, and are never dropped.
  """

  @default_max 20_000
  # What a restart must not lose.
  @durable ~w(job:finished worktree:removed)

  @opaque t :: %{
            max: pos_integer(),
            path: Path.t() | nil,
            next: non_neg_integer(),
            entries: :gb_trees.tree(non_neg_integer(), {String.t(), map()}),
            refs: %{optional(term()) => non_neg_integer()},
            dropped: non_neg_integer()
          }

  @doc """
  An outbox holding up to `max` messages; with a `path`, starting with the
  messages a previous run kept there.
  """
  @spec new(pos_integer(), Path.t() | nil) :: t()
  def new(max \\ @default_max, path \\ nil) do
    kept = load(path)
    entries = kept |> Enum.with_index() |> Enum.map(fn {entry, id} -> {id, entry} end)

    %{
      max: max,
      path: path,
      next: length(kept),
      entries: :gb_trees.from_orddict(entries),
      refs: %{},
      dropped: 0
    }
  end

  @doc "Adds a message; returns its id, to mark it `sent/3`."
  @spec add(t(), String.t(), map()) :: {non_neg_integer(), t()}
  def add(outbox, event, payload) do
    id = outbox.next
    entries = :gb_trees.insert(id, {event, payload}, outbox.entries)
    outbox = trim(%{outbox | next: id + 1, entries: entries})
    if event in @durable, do: save(outbox)
    {id, outbox}
  end

  @doc "The message `id` was pushed and `ref` will carry its reply."
  @spec sent(t(), non_neg_integer(), term()) :: t()
  def sent(outbox, id, ref), do: %{outbox | refs: Map.put(outbox.refs, ref, id)}

  @doc "The reply to `ref` arrived: its message is done."
  @spec confirmed(t(), term()) :: t()
  def confirmed(outbox, ref) do
    case Map.pop(outbox.refs, ref) do
      {nil, _refs} ->
        outbox

      {id, refs} ->
        durable =
          match?(
            {:value, {event, _}} when event in @durable,
            :gb_trees.lookup(id, outbox.entries)
          )

        outbox = %{outbox | refs: refs, entries: :gb_trees.delete_any(id, outbox.entries)}
        if durable, do: save(outbox)
        outbox
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

  @doc "How many messages it dropped for lack of room, since it was created."
  @spec dropped(t()) :: non_neg_integer()
  def dropped(outbox), do: outbox.dropped

  @doc "How many messages are still to confirm."
  @spec size(t()) :: non_neg_integer()
  def size(outbox), do: :gb_trees.size(outbox.entries)

  @doc "The jobs with messages still to confirm."
  @spec job_ids(t()) :: [String.t()]
  def job_ids(outbox) do
    outbox
    |> pending()
    |> Enum.map(fn {_id, _event, payload} -> payload["job_id"] end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  @doc """
  Writes every message still to confirm to the file, not only those a
  restart must not lose: before the runner updates itself, so the new one
  sends it all.
  """
  @spec persist_all(t()) :: :ok
  def persist_all(%{path: nil}), do: :ok
  def persist_all(outbox), do: write(outbox.path, Enum.map(pending(outbox), &entry/1))

  defp entry({_id, event, payload}), do: {event, payload}

  @doc """
  The jobs whose end is still to confirm: they count as running for the
  control plane until it has it. A job with only its start or events here
  (one stopped as lost before an update) does not.
  """
  @spec finished_job_ids(t()) :: [String.t()]
  def finished_job_ids(outbox) do
    for({_id, "job:finished", %{"job_id" => id}} <- pending(outbox), do: id)
    |> Enum.uniq()
  end

  defp load(nil), do: []

  # A missing or unreadable file starts empty: no reason not to start.
  defp load(path) do
    with {:ok, binary} <- File.read(path),
         {:ok, entries} <- decode(binary) do
      entries
    else
      _missing_or_corrupt -> []
    end
  end

  defp decode(binary) do
    case :erlang.binary_to_term(binary, [:safe]) do
      entries when is_list(entries) -> {:ok, entries}
      _other -> :error
    end
  rescue
    ArgumentError -> :error
  end

  defp save(%{path: nil}), do: :ok

  defp save(%{path: path} = outbox) do
    durable =
      for {_id, {event, _} = entry} <- :gb_trees.to_list(outbox.entries),
          event in @durable,
          do: entry

    write(path, durable)
  end

  defp write(path, entries) do
    temp = path <> ".tmp"
    File.mkdir_p!(Path.dirname(path))
    File.write!(temp, :erlang.term_to_binary(entries))
    File.rename!(temp, path)
  end

  defp trim(outbox) do
    if :gb_trees.size(outbox.entries) > outbox.max,
      do: drop_oldest_event(outbox),
      else: outbox
  end

  # What can go when full: a job's events and telemetry, never its start or end.
  @droppable ~w(job:event job:telemetry runner:log)

  defp drop_oldest_event(outbox) do
    case Enum.find(pending(outbox), fn {_id, event, _payload} -> event in @droppable end) do
      nil ->
        outbox

      {id, _event, _payload} ->
        trim(%{
          outbox
          | entries: :gb_trees.delete(id, outbox.entries),
            dropped: outbox.dropped + 1
        })
    end
  end
end
