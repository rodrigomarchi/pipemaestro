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
      (`run_stats/2`);
    * its own log (`PipeMaestro.RunnerTelemetry.LogLine`), kept for its
      workspace's `runner_log_retention_days`, and the events that happened
      to it (`PipeMaestro.RunnerTelemetry.Event`), from its log and from
      what its jobs reported;
    * its latest diagnosis (`record_doctor/2`, kept on the runner), and an
      event each time a check changes status;
    * from all of that, whether it is degraded and why (`degraded/2`).
  """

  import Ecto.Query

  alias PipeMaestro.Jobs.Job
  alias PipeMaestro.Repo
  alias PipeMaestro.Runners.Runner
  alias PipeMaestro.RunnerTelemetry.{Event, HealthSample, LogLine, Session}
  alias PipeMaestro.Tasks.StageRun
  alias PipeMaestro.Workspaces.Workspace
  alias PipeMaestroProtocol.{RunnerDoctor, RunnerHealth, RunnerLog}

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

  # ── Log and events ────────────────────────────────────────────────────────

  @levels ~w(debug info warning error)
  @events_days 30

  @doc """
  Whether the workspace of `runner` keeps its runners' log lines (a
  retention above 0 days); otherwise only their events.
  """
  @spec keep_logs?(Runner.t()) :: boolean()
  def keep_logs?(%Runner{workspace_id: id}) do
    # Read each time: the setting may change while the runner is connected.
    Repo.one!(from w in Workspace, where: w.id == ^id, select: w.runner_log_retention_days) > 0
  end

  @doc """
  Stores a `runner:log` message of `runner`
  (`PipeMaestroProtocol.RunnerLog`): its lines, when the workspace keeps
  them, and the events among them. Returns how many lines it got.
  """
  @spec record_log(Runner.t(), term()) :: {:ok, non_neg_integer()} | {:error, String.t()}
  def record_log(%Runner{} = runner, payload) do
    with {:ok, lines} <- RunnerLog.parse(payload) do
      if keep_logs?(runner), do: Repo.insert_all(LogLine, Enum.map(lines, &log_row(runner, &1)))

      for %{"event" => kind} = line <- lines, kind != nil do
        record_event(runner, kind, line["level"], line["message"],
          at: line["at"],
          attrs: line["attrs"],
          job_id: uuid(line["attrs"]["job_id"])
        )
      end

      {:ok, length(lines)}
    end
  end

  defp log_row(runner, line) do
    %{
      id: Ecto.UUID.generate(),
      runner_id: runner.id,
      workspace_id: runner.workspace_id,
      at: to_usec(line["at"]),
      level: line["level"],
      message: line["message"],
      event: line["event"]
    }
  end

  @doc """
  Stores an event of `runner`: `kind` from `Event.kinds/0`, `level` one of
  debug, info, warning or error. Options: `:at` (default now), `:attrs`,
  `:job_id`, `:task_id`.
  """
  @spec record_event(Runner.t(), String.t(), String.t(), String.t(), keyword()) :: Event.t()
  def record_event(%Runner{} = runner, kind, level, message, opts \\ [])
      when level in @levels do
    Repo.insert!(%Event{
      runner_id: runner.id,
      workspace_id: runner.workspace_id,
      at: to_usec(Keyword.get_lazy(opts, :at, &DateTime.utc_now/0)),
      kind: kind,
      level: level,
      message: String.slice(message, 0, 4_000),
      attrs: Keyword.get(opts, :attrs) || %{},
      job_id: Keyword.get(opts, :job_id),
      task_id: Keyword.get(opts, :task_id)
    })
  end

  @doc """
  The events in what a job of `runner` reported as it finished (`payload`,
  as `job:finished` carries it): a setup that failed, and a delivery that
  failed, as `credential_refused` when git was refused the credential.
  Works with any runner, the old ones included. Returns the events stored.
  """
  @spec record_job_outcome(Runner.t(), Ecto.UUID.t(), map()) :: [Event.t()]
  def record_job_outcome(%Runner{} = runner, job_id, payload) when is_map(payload) do
    events =
      [setup_failure(payload["setup"]), delivery_failure(payload["delivery"])]
      |> Enum.reject(&is_nil/1)

    if events == [] do
      []
    else
      task_id = task_of(job_id)

      for {kind, level, message, attrs} <- events do
        record_event(runner, kind, level, message,
          attrs: attrs,
          job_id: job_id,
          task_id: task_id
        )
      end
    end
  end

  def record_job_outcome(_runner, _job_id, _payload), do: []

  @doc "Stores that `runner` could not remove the worktree of `task_id`."
  @spec record_worktree_failure(Runner.t(), Ecto.UUID.t(), String.t()) :: Event.t()
  def record_worktree_failure(%Runner{} = runner, task_id, error) do
    record_event(runner, "worktree_remove_failed", "warning", "O worktree não saiu: #{error}",
      task_id: uuid(task_id)
    )
  end

  @doc """
  The runner's events from `since`, newest first, at most `limit`: all of
  them, or those of a `group` (`Event.group/1`), or `"errors"` for the
  errors only.
  """
  @spec events(Runner.t(), DateTime.t(), String.t() | nil, pos_integer()) :: [Event.t()]
  def events(%Runner{id: id}, since, group \\ nil, limit \\ 200) do
    from(e in Event,
      where: e.runner_id == ^id and e.at >= ^since,
      order_by: [desc: e.at],
      limit: ^limit
    )
    |> filter_group(group)
    |> Repo.all()
  end

  @doc """
  The runner's latest `limit` log lines at `min_level` or above, oldest
  first.
  """
  @spec log_lines(Runner.t(), String.t(), pos_integer()) :: [LogLine.t()]
  def log_lines(%Runner{id: id}, min_level \\ "debug", limit \\ 500) do
    levels = Enum.drop_while(@levels, &(&1 != min_level))

    from(l in LogLine,
      where: l.runner_id == ^id and l.level in ^levels,
      order_by: [desc: l.at],
      limit: ^limit
    )
    |> Repo.all()
    |> Enum.reverse()
  end

  @doc """
  Removes the log lines past their workspace's retention, as of `now`, and
  the events older than #{@events_days} days. Returns how many of each.
  """
  @spec prune_logs(DateTime.t()) :: %{lines: non_neg_integer(), events: non_neg_integer()}
  def prune_logs(now) do
    {lines, _} =
      Repo.delete_all(
        from l in LogLine,
          join: w in Workspace,
          on: w.id == l.workspace_id,
          where:
            l.at <
              fragment(
                "? - make_interval(days => ?)",
                type(^now, :utc_datetime_usec),
                w.runner_log_retention_days
              )
      )

    {events, _} =
      Repo.delete_all(from e in Event, where: e.at < ^DateTime.add(now, -@events_days, :day))

    %{lines: lines, events: events}
  end

  # ── Degraded ──────────────────────────────────────────────────────────────

  @typedoc """
  Why a runner is degraded: little free disk (the bytes left), memory
  nearly full for its last samples, dropped connections in the last hour
  (how many), too many failed jobs in the last day (the share), or checks
  of its diagnosis in error (their names).
  """
  @type reason ::
          {:disk, non_neg_integer()}
          | :memory
          | {:drops, pos_integer()}
          | {:failures, float()}
          | {:doctor, [String.t()]}

  @low_disk_share 0.10
  @low_disk_bytes 5 * 1024 * 1024 * 1024
  @full_memory_share 0.95
  @memory_samples 5
  @max_drops_hour 3
  @max_failure_rate 0.30
  @min_runs 5
  # An older sample says nothing about the machine now.
  @fresh_sample_seconds 600

  @doc """
  Why `runner` is degraded as of `now`, or `[]`: free disk under 10% or
  5 GiB, memory over 95% in its last five samples, #{@max_drops_hour} or more
  dropped connections in the last hour, more than 30% of its jobs failed in
  the last day (with at least #{@min_runs}), or a check of its diagnosis in
  error. Only samples from the last ten minutes count.
  """
  @spec degraded(Runner.t(), DateTime.t()) :: [reason()]
  def degraded(%Runner{} = runner, now \\ DateTime.utc_now()) do
    samples =
      runner
      |> recent_health(@memory_samples)
      |> Enum.filter(&(DateTime.diff(now, &1.at) <= @fresh_sample_seconds))

    Enum.reject(
      [
        disk_reason(List.first(samples)),
        memory_reason(samples),
        drops_reason(drops(runner, DateTime.add(now, -1, :hour), now)),
        failures_reason(run_stats(runner, DateTime.add(now, -1, :day))),
        doctor_reason(runner.doctor)
      ],
      &is_nil/1
    )
  end

  @doc """
  The degraded runners among `runners`, as `{:runner_degraded, runner,
  reasons}`, for the board's alerts.
  """
  @spec degraded_alerts([Runner.t()], DateTime.t()) :: [
          {:runner_degraded, Runner.t(), [reason()]}
        ]
  def degraded_alerts(runners, now \\ DateTime.utc_now()) do
    for runner <- runners,
        reasons = degraded(runner, now),
        reasons != [],
        do: {:runner_degraded, runner, reasons}
  end

  defp disk_reason(%HealthSample{disk_free_bytes: free} = sample) when is_integer(free) do
    share = HealthSample.disk_free_share(sample)
    if free < @low_disk_bytes or (share && share < @low_disk_share), do: {:disk, free}
  end

  defp disk_reason(_sample), do: nil

  defp memory_reason(samples) when length(samples) == @memory_samples do
    shares = Enum.map(samples, &HealthSample.mem_share/1)
    if Enum.all?(shares, &(is_float(&1) and &1 > @full_memory_share)), do: :memory
  end

  defp memory_reason(_samples), do: nil

  defp drops_reason(count) when count >= @max_drops_hour, do: {:drops, count}
  defp drops_reason(_count), do: nil

  defp failures_reason(%{runs: runs, failure_rate: rate})
       when runs >= @min_runs and rate > @max_failure_rate,
       do: {:failures, rate}

  defp failures_reason(_stats), do: nil

  defp doctor_reason(%{"checks" => checks}) when is_list(checks) do
    case for(%{"status" => "error", "name" => name} <- checks, do: name) do
      [] -> nil
      names -> {:doctor, names}
    end
  end

  defp doctor_reason(_doctor), do: nil

  # ── Diagnosis ──────────────────────────────────────────────────────────────

  @doc """
  Stores the diagnosis `runner` sent (`PipeMaestroProtocol.RunnerDoctor`)
  as its latest, and an event (`doctor_changed`) for each check whose status
  changed since the previous one; on the first, for each check not ok.
  """
  @spec record_doctor(Runner.t(), term()) :: {:ok, Runner.t()} | {:error, String.t()}
  def record_doctor(%Runner{} = runner, payload) do
    with {:ok, diagnosis} <- RunnerDoctor.parse(payload) do
      previous = Repo.one(from r in Runner, where: r.id == ^runner.id, select: r.doctor)
      before = Map.new((previous || %{})["checks"] || [], &{&1["key"], &1["status"]})

      for check <- diagnosis["checks"],
          changed?(before, check, previous == nil) do
        record_event(
          runner,
          "doctor_changed",
          event_level(check["status"]),
          doctor_message(before, check),
          at: diagnosis["at"],
          attrs: %{
            "key" => check["key"],
            "status" => check["status"],
            "was" => before[check["key"]]
          }
        )
      end

      stored = %{diagnosis | "at" => DateTime.to_iso8601(diagnosis["at"])}
      runner |> Ecto.Changeset.change(doctor: stored) |> Repo.update()
    end
  end

  defp changed?(_before, %{"status" => status}, true = _first), do: status != "ok"
  defp changed?(before, %{"key" => key, "status" => status}, false), do: before[key] != status

  defp event_level("ok"), do: "info"
  defp event_level(status), do: status

  defp doctor_message(before, %{
         "key" => key,
         "name" => name,
         "status" => status,
         "detail" => detail
       }) do
    case before[key] do
      nil ->
        "Diagnóstico: #{name} #{status_label(status)}: #{detail}"

      was ->
        "Diagnóstico: #{name} passou de #{status_label(was)} a #{status_label(status)}: #{detail}"
    end
  end

  defp status_label("ok"), do: "ok"
  defp status_label("warning"), do: "atenção"
  defp status_label("error"), do: "erro"
  defp status_label(other), do: other

  defp filter_group(query, nil), do: query
  defp filter_group(query, "errors"), do: where(query, [e], e.level == "error")
  defp filter_group(query, group), do: where(query, [e], e.kind in ^Event.kinds_of(group))

  defp setup_failure(%{"exit_code" => code} = setup) when is_integer(code) and code != 0 do
    {"setup_failed", "error", "O setup do worktree falhou (saída #{code}).",
     %{"command" => setup["command"], "exit_code" => code, "output" => tail(setup["output"])}}
  end

  defp setup_failure(_setup), do: nil

  # git's own words when the host refused the credential.
  @refused ~r/(Authentication failed|could not read Username|invalid credentials|401|403|denied)/i

  defp delivery_failure(%{"error" => error}) when is_binary(error) and error != "" do
    if Regex.match?(@refused, error),
      do: {"credential_refused", "error", "O host recusou a credencial git: #{tail(error)}", %{}},
      else: {"delivery_failed", "error", "A entrega no git falhou: #{tail(error)}", %{}}
  end

  defp delivery_failure(_delivery), do: nil

  defp tail(nil), do: nil

  defp tail(text) do
    if String.length(text) <= 1_000, do: text, else: "…" <> String.slice(text, -1_000, 1_000)
  end

  defp task_of(job_id) do
    Repo.one(
      from j in Job,
        join: r in StageRun,
        on: r.id == j.stage_run_id,
        where: j.id == ^job_id,
        select: r.task_id
    )
  end

  defp uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  defp uuid(_value), do: nil

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
