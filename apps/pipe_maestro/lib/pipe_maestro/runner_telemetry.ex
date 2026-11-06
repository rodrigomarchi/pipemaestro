defmodule PipeMaestro.RunnerTelemetry do
  @moduledoc """
  What the control plane learns about a runner as a machine and a process
  (ADR 0039), apart from the jobs it runs:

    * its connections (`PipeMaestro.RunnerTelemetry.Session`), observed by
      the control plane itself: when each began and ended, why, and the
      uptime they add up to;
    * its machine's health (`PipeMaestro.RunnerTelemetry.HealthSample`), a
      sample a minute, as series for charts;
    * how its finished jobs went: failures, setup, queue and gates
      (`run_stats/2`).
  """

  import Ecto.Query

  alias PipeMaestro.Jobs.Job
  alias PipeMaestro.Repo
  alias PipeMaestro.Runners.Runner
  alias PipeMaestro.RunnerTelemetry.{HealthSample, Session}
  alias PipeMaestroProtocol.RunnerHealth

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

  # ── Health ────────────────────────────────────────────────────────────────

  @floats ~w(cpu_pct load1)a
  @integers ~w(mem_used_bytes mem_total_bytes disk_free_bytes disk_total_bytes outbox_pending
               running_jobs beam_bytes)a

  @doc """
  Stores a health sample `runner` sent, in the wire form of
  `PipeMaestroProtocol.RunnerHealth`. A sample dated in the future (a clock
  ahead) is dated now.
  """
  @spec record_health(Runner.t(), term(), DateTime.t()) ::
          {:ok, HealthSample.t()} | {:error, String.t()}
  def record_health(%Runner{} = runner, payload, now \\ DateTime.utc_now()) do
    with {:ok, sample} <- RunnerHealth.parse(payload) do
      at = if DateTime.compare(sample["at"], now) == :gt, do: now, else: sample["at"]

      measures =
        Enum.map(@floats, &{&1, to_float(sample[Atom.to_string(&1)])}) ++
          Enum.map(@integers, &{&1, to_integer(sample[Atom.to_string(&1)])})

      {:ok,
       Repo.insert!(
         struct!(
           HealthSample,
           [runner_id: runner.id, workspace_id: runner.workspace_id, at: to_usec(at)] ++ measures
         )
       )}
    end
  end

  @doc "Removes the health samples taken before `before`; returns how many."
  @spec prune_health(DateTime.t()) :: non_neg_integer()
  def prune_health(before) do
    {count, _} = Repo.delete_all(from s in HealthSample, where: s.at < ^before)
    count
  end

  @doc "The runner's latest health sample, or `nil`."
  @spec latest_health(Runner.t()) :: HealthSample.t() | nil
  def latest_health(%Runner{id: id}) do
    Repo.one(from s in HealthSample, where: s.runner_id == ^id, order_by: [desc: s.at], limit: 1)
  end

  @doc "The runner's latest `count` health samples, newest first."
  @spec recent_health(Runner.t(), pos_integer()) :: [HealthSample.t()]
  def recent_health(%Runner{id: id}, count) do
    Repo.all(
      from s in HealthSample, where: s.runner_id == ^id, order_by: [desc: s.at], limit: ^count
    )
  end

  @doc """
  The runner's health from `since`, averaged in buckets of `bucket_seconds`,
  oldest first: `%{at, cpu_pct, load1, mem_pct, disk_free_bytes,
  outbox_pending}`, `mem_pct` from 0 to 100 and the disk the least free in
  the bucket. A bucket without samples is missing (the runner was offline).
  """
  @spec health_series(Runner.t(), DateTime.t(), pos_integer()) :: [map()]
  def health_series(%Runner{id: id}, since, bucket_seconds) do
    from(s in HealthSample,
      where: s.runner_id == ^id and s.at >= ^since,
      group_by: selected_as(:bucket),
      order_by: selected_as(:bucket),
      select: %{
        at:
          selected_as(
            fragment("date_bin(make_interval(secs => ?), ?, ?)", ^bucket_seconds, s.at, ^since),
            :bucket
          ),
        cpu_pct: avg(s.cpu_pct),
        load1: avg(s.load1),
        mem_pct: avg(fragment("100.0 * ? / NULLIF(?, 0)", s.mem_used_bytes, s.mem_total_bytes)),
        disk_free_bytes: min(s.disk_free_bytes),
        outbox_pending: max(s.outbox_pending)
      }
    )
    |> Repo.all()
    |> Enum.map(fn row ->
      %{
        row
        | cpu_pct: to_float(row.cpu_pct),
          load1: to_float(row.load1),
          mem_pct: to_float(row.mem_pct)
      }
    end)
  end

  @doc """
  How the runner's jobs that finished from `since` went: `runs` (succeeded or
  failed), `failed`, `failure_rate` (0 to 1, `nil` with no runs), and the
  median and 95th percentile of the setup, the median wait in the queue and
  the median time in the gates, in ms (`nil` with nothing measured).
  """
  @spec run_stats(Runner.t(), DateTime.t()) :: map()
  def run_stats(%Runner{id: id}, since) do
    row =
      Repo.one(
        from j in Job,
          where:
            j.runner_id == ^id and j.finished_at >= ^since and j.status in [:succeeded, :failed],
          select: %{
            runs: count(j.id),
            failed: filter(count(j.id), j.status == :failed),
            setup_p50:
              fragment(
                "percentile_cont(0.5) WITHIN GROUP (ORDER BY (?->>'duration_ms')::numeric)",
                j.setup
              ),
            setup_p95:
              fragment(
                "percentile_cont(0.95) WITHIN GROUP (ORDER BY (?->>'duration_ms')::numeric)",
                j.setup
              ),
            queue_p50:
              fragment(
                "percentile_cont(0.5) WITHIN GROUP (ORDER BY extract(epoch FROM ? - ?) * 1000)",
                j.started_at,
                j.inserted_at
              ),
            gates_p50:
              fragment(
                "percentile_cont(0.5) WITHIN GROUP (ORDER BY (?->'timing'->>'gates')::numeric)",
                j.insights
              )
          }
      )

    %{
      runs: row.runs,
      failed: row.failed,
      failure_rate: if(row.runs > 0, do: row.failed / row.runs),
      setup_p50_ms: to_ms(row.setup_p50),
      setup_p95_ms: to_ms(row.setup_p95),
      queue_p50_ms: to_ms(row.queue_p50),
      gates_p50_ms: to_ms(row.gates_p50)
    }
  end

  @doc """
  The share of failed jobs among those that finished from `since`, by runner
  id; `nil` for a runner with none.
  """
  @spec failure_rates([Runner.t()], DateTime.t()) :: %{Ecto.UUID.t() => float() | nil}
  def failure_rates(runners, since) do
    ids = Enum.map(runners, & &1.id)

    counts =
      Repo.all(
        from j in Job,
          where:
            j.runner_id in ^ids and j.finished_at >= ^since and j.status in [:succeeded, :failed],
          group_by: j.runner_id,
          select: {j.runner_id, count(j.id), filter(count(j.id), j.status == :failed)}
      )
      |> Map.new(fn {id, runs, failed} -> {id, failed / runs} end)

    Map.new(ids, &{&1, Map.get(counts, &1)})
  end

  defp to_float(nil), do: nil
  defp to_float(%Decimal{} = value), do: Decimal.to_float(value)
  defp to_float(value) when is_number(value), do: value * 1.0

  defp to_integer(nil), do: nil
  defp to_integer(value) when is_integer(value), do: value
  defp to_integer(value) when is_float(value), do: round(value)

  defp to_ms(nil), do: nil
  defp to_ms(value), do: value |> to_float() |> round()

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
