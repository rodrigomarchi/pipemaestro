defmodule PipeMaestro.Maintenance do
  @moduledoc """
  Housekeeping that runs on its own, every `:every` ms (default one hour):

    * sign-in requests of runners (device flow) a day past their expiry go;
    * jobs that ended without a kept summary get one
      (`PipeMaestro.Insights.store_summary/1`), at most `:batch` (default
      500) per run;
    * the events and the OpenTelemetry records of jobs that ended more than
      `:job_events_days` ago (default 30) go, once the job's summary is
      written from them: the job keeps its outcome, cost, tokens, artifact,
      the totals and the summary of its run. At most `:batch` jobs per run;
      the rest go on the next.
    * audit entries older than `:audit_days` (default 365) go;
    * the integrations' deliveries older than `:deliveries_days` (default 30)
      go (`PipeMaestro.Integrations.prune_deliveries/1`).

  When it starts, it also closes the runners' sessions the previous run of
  the control plane left open (`PipeMaestro.RunnerTelemetry.close_orphan_sessions/1`).

  A process on each node of the control plane; with more than one node, a
  shared job queue would keep two from doing the same work.
  """
  use GenServer

  import Ecto.Query

  alias PipeMaestro.{Audit, Insights, Integrations, Repo, RunnerTelemetry}
  alias PipeMaestro.Jobs.{Event, Job, Telemetry}
  alias PipeMaestro.Runners.DeviceAuthorization

  @doc "Starts the periodic housekeeping. Options: `:every` (ms)."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Does the housekeeping once, as of `now`; returns how much each part removed."
  @spec run(DateTime.t(), keyword()) :: %{atom() => non_neg_integer()}
  def run(now, opts \\ []) do
    job_events_days = Keyword.get(opts, :job_events_days, 30)
    audit_days = Keyword.get(opts, :audit_days, 365)
    deliveries_days = Keyword.get(opts, :deliveries_days, 30)
    batch = Keyword.get(opts, :batch, 500)

    {device_authorizations, _} =
      Repo.delete_all(
        from a in DeviceAuthorization, where: a.expires_at < ^DateTime.add(now, -1, :day)
      )

    summarized =
      Repo.all(
        from j in Job, where: not is_nil(j.finished_at) and is_nil(j.insights), limit: ^batch
      )

    Enum.each(summarized, &Insights.store_summary/1)

    # The jobs past retention that still have events or records: their
    # summary is written once more, final, before those go.
    old_jobs =
      Repo.all(
        from j in Job,
          as: :job,
          where:
            j.finished_at < ^DateTime.add(now, -job_events_days, :day) and
              (exists(from e in Event, where: e.job_id == parent_as(:job).id, select: 1) or
                 exists(from t in Telemetry, where: t.job_id == parent_as(:job).id, select: 1)),
          limit: ^batch
      )

    Enum.each(old_jobs, &Insights.store_summary/1)
    old_ids = Enum.map(old_jobs, & &1.id)

    {job_events, _} = Repo.delete_all(from e in Event, where: e.job_id in ^old_ids)
    {job_telemetry, _} = Repo.delete_all(from t in Telemetry, where: t.job_id in ^old_ids)

    %{
      device_authorizations: device_authorizations,
      summarized: length(summarized),
      job_events: job_events,
      job_telemetry: job_telemetry,
      audit_events: Audit.prune(DateTime.add(now, -audit_days, :day)),
      deliveries: Integrations.prune_deliveries(DateTime.add(now, -deliveries_days, :day))
    }
  end

  @impl true
  def init(opts) do
    every = Keyword.get(opts, :every, :timer.hours(1))
    Process.send_after(self(), :run, every)
    {:ok, %{every: every, opts: opts}, {:continue, {:close_orphans, DateTime.utc_now()}}}
  end

  # Only sessions opened before this start: a runner already back has a new one.
  @impl true
  def handle_continue({:close_orphans, started}, state) do
    _closed = RunnerTelemetry.close_orphan_sessions(started)
    {:noreply, state}
  end

  @impl true
  def handle_info(:run, state) do
    _removed = run(DateTime.utc_now(), state.opts)
    Process.send_after(self(), :run, state.every)
    {:noreply, state}
  end
end
