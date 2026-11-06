defmodule PipeMaestro.RunnerTelemetry do
  @moduledoc """
  What the control plane learns about a runner as a machine and a process
  (ADR 0039), apart from the jobs it runs:

    * its connections (`PipeMaestro.RunnerTelemetry.Session`), observed by
      the control plane itself: when each began and ended, why, and the
      uptime they add up to.
  """

  import Ecto.Query

  alias PipeMaestro.Repo
  alias PipeMaestro.Runners.Runner
  alias PipeMaestro.RunnerTelemetry.Session

  # ── Connections ───────────────────────────────────────────────────────────

  @doc """
  Opens a session for `runner`, which has just joined. A session of it still
  open (the previous connection's end not seen yet) is closed as
  `reconnected`.
  """
  @spec open_session(Runner.t(), DateTime.t()) :: Session.t()
  def open_session(%Runner{} = runner, now \\ DateTime.utc_now()) do
    close_open(runner.id, "reconnected", now)

    Repo.insert!(%Session{
      runner_id: runner.id,
      workspace_id: runner.workspace_id,
      started_at: now,
      runner_version: runner.runner_version
    })
  end

  @doc """
  Closes the session `id` with `reason` (one of `Session.reasons/0`), if it
  is still open.
  """
  @spec close_session(Ecto.UUID.t(), String.t(), DateTime.t()) :: :ok
  def close_session(id, reason, now \\ DateTime.utc_now())
      when reason in ~w(closed revoked crashed) do
    Repo.update_all(from(s in Session, where: s.id == ^id and is_nil(s.ended_at)),
      set: [ended_at: now, end_reason: reason]
    )

    :ok
  end

  @doc """
  Records a refused join of `runner` (`reason` from `Session.refusals/0`):
  a session that ends as it starts, with the version the runner announced.
  """
  @spec record_refusal(Runner.t(), String.t(), String.t() | nil, DateTime.t()) :: Session.t()
  def record_refusal(%Runner{} = runner, reason, version, now \\ DateTime.utc_now())
      when reason in ~w(outdated invalid_hello) do
    Repo.insert!(%Session{
      runner_id: runner.id,
      workspace_id: runner.workspace_id,
      started_at: now,
      ended_at: now,
      end_reason: reason,
      runner_version: if(is_binary(version), do: String.slice(version, 0, 40))
    })
  end

  @doc """
  Closes, as `restart`, every session opened before `before` and still open:
  the control plane went down without seeing them end. Returns how many.
  """
  @spec close_orphan_sessions(DateTime.t()) :: non_neg_integer()
  def close_orphan_sessions(before) do
    {count, _} =
      Repo.update_all(
        from(s in Session, where: is_nil(s.ended_at) and s.started_at < ^before),
        set: [ended_at: before, end_reason: "restart"]
      )

    count
  end

  @doc "The runner's sessions that touch the period from `since`, newest first."
  @spec sessions(Runner.t(), DateTime.t(), pos_integer()) :: [Session.t()]
  def sessions(%Runner{id: id}, since, limit \\ 200) do
    Repo.all(
      from s in Session,
        where: s.runner_id == ^id and (is_nil(s.ended_at) or s.ended_at >= ^since),
        order_by: [desc: s.started_at],
        limit: ^limit
    )
  end

  @doc """
  The share of the period from `since` to `now` each runner spent
  connected, from 0 to 1, by runner id. The period of a runner starts when
  it was created, if later; a runner created at `now` has none (`nil`).
  """
  @spec uptimes([Runner.t()], DateTime.t(), DateTime.t()) :: %{Ecto.UUID.t() => float() | nil}
  def uptimes(runners, since, now \\ DateTime.utc_now()) do
    ids = Enum.map(runners, & &1.id)

    sessions =
      Repo.all(
        from s in Session,
          where:
            s.runner_id in ^ids and s.started_at < ^now and
              (is_nil(s.ended_at) or s.ended_at > ^since),
          select: {s.runner_id, s.started_at, s.ended_at}
      )
      |> Enum.group_by(&elem(&1, 0), &{elem(&1, 1), elem(&1, 2)})

    Map.new(runners, fn runner ->
      from = latest(since, runner.inserted_at)
      {runner.id, connected_share(Map.get(sessions, runner.id, []), from, now)}
    end)
  end

  @doc "The share of the period from `since` to `now` the runner spent connected."
  @spec uptime(Runner.t(), DateTime.t(), DateTime.t()) :: float() | nil
  def uptime(%Runner{} = runner, since, now \\ DateTime.utc_now()),
    do: Map.fetch!(uptimes([runner], since, now), runner.id)

  @doc """
  How many of the runner's connections ended, other than by revocation,
  between `since` and `now`: the drops.
  """
  @spec drops(Runner.t(), DateTime.t(), DateTime.t()) :: non_neg_integer()
  def drops(%Runner{id: id}, since, now \\ DateTime.utc_now()) do
    Repo.aggregate(
      from(s in Session,
        where:
          s.runner_id == ^id and s.ended_at >= ^since and s.ended_at <= ^now and
            s.end_reason in ~w(closed crashed restart)
      ),
      :count
    )
  end

  defp connected_share(sessions, from, now) do
    total = DateTime.diff(now, from, :millisecond)

    if total <= 0 do
      nil
    else
      connected =
        sessions
        |> Enum.map(fn {started, ended} ->
          {latest(started, from), earliest(ended || now, now)}
        end)
        |> Enum.filter(fn {a, b} -> DateTime.compare(b, a) == :gt end)
        |> merge()
        |> Enum.map(fn {a, b} -> DateTime.diff(b, a, :millisecond) end)
        |> Enum.sum()

      min(connected / total, 1.0)
    end
  end

  # Overlapping intervals (a reconnect seen before the old one's end) count once.
  defp merge(intervals) do
    intervals
    |> Enum.sort_by(&elem(&1, 0), DateTime)
    |> Enum.reduce([], fn
      {a, b}, [{pa, pb} | rest] ->
        if DateTime.compare(a, pb) == :gt,
          do: [{a, b}, {pa, pb} | rest],
          else: [{pa, latest(pb, b)} | rest]

      interval, [] ->
        [interval]
    end)
  end

  defp close_open(runner_id, reason, now) do
    Repo.update_all(from(s in Session, where: s.runner_id == ^runner_id and is_nil(s.ended_at)),
      set: [ended_at: now, end_reason: reason]
    )
  end

  defp latest(a, nil), do: a
  defp latest(a, b), do: if(DateTime.compare(a, b) == :lt, do: to_usec(b), else: to_usec(a))
  defp earliest(a, b), do: if(DateTime.compare(a, b) == :gt, do: b, else: a)

  defp to_usec(%DateTime{microsecond: {_value, 6}} = at), do: at
  defp to_usec(at), do: DateTime.add(at, 0, :microsecond)
end
