defmodule PipeMaestro.Maintenance do
  @moduledoc """
  Housekeeping that runs on its own, every `:every` ms (default one hour):

    * sign-in requests of runners (device flow) a day past their expiry go;
    * jobs that ended without a kept summary get one
      (`PipeMaestro.Insights.store_summary/1`), at most `:batch` (default
      500) per run;
    * past their workspace's `agent_events_retention_days` from when they
      ended, the jobs' OpenTelemetry records go and their events either go
      (`:delete`) or keep only their metadata (`:metadata`,
      `PipeMaestro.Jobs.Event.metadata_only/1`), once the job's summary is
      written from them: the job keeps its outcome, cost, tokens, artifact,
      the totals and the summary of its run, and is marked
      (`events_pruned_at`) so it is not taken again. At most `:batch` jobs
      per run; the rest go on the next.
    * the jobs' files past their workspace's `job_files_retention_days` lose
      their content, keeping their name (`PipeMaestro.Jobs.Files.prune/2`),
      at most `:batch` per run;
    * audit entries older than `:audit_days` (default 365) go;
    * the integrations' deliveries older than `:deliveries_days` (default 30)
      go (`PipeMaestro.Integrations.prune_deliveries/1`);
    * the runners' health samples older than `:health_days` (default 7) go
      (`PipeMaestro.RunnerTelemetry.prune_health/1`), and so do their log
      lines past their workspace's retention and their events past 30 days
      (`PipeMaestro.RunnerTelemetry.prune_logs/1`);
    * notifications read more than `:notifications_days` ago (default 30)
      go (`PipeMaestro.Notifications.delete_read_before/1`); unread ones stay.

  When it starts, it also closes the runners' sessions the previous run of
  the control plane left open (`PipeMaestro.RunnerTelemetry.close_orphan_sessions/1`).

  A process on each node of the control plane; with more than one node, a
  shared job queue would keep two from doing the same work.
  """
  use GenServer

  import Ecto.Query

  alias PipeMaestro.{Audit, Insights, Integrations, Notifications, Repo, RunnerTelemetry}
  alias PipeMaestro.Jobs.{Event, Files, Job, Telemetry}
  alias PipeMaestro.Workspaces.Workspace
  alias PipeMaestro.Runners.DeviceAuthorization

  @doc "Starts the periodic housekeeping. Options: `:every` (ms)."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Does the housekeeping once, as of `now`; returns how much each part removed."
  @spec run(DateTime.t(), keyword()) :: %{atom() => non_neg_integer()}
  def run(now, opts \\ []) do
    audit_days = Keyword.get(opts, :audit_days, 365)
    deliveries_days = Keyword.get(opts, :deliveries_days, 30)
    health_days = Keyword.get(opts, :health_days, 7)
    notifications_days = Keyword.get(opts, :notifications_days, 30)
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

    pruned = prune_events(now, batch)

    %{
      device_authorizations: device_authorizations,
      summarized: length(summarized),
      job_events: pruned.deleted,
      job_events_stripped: pruned.stripped,
      job_telemetry: pruned.telemetry,
      job_files: Files.prune(now, batch: batch),
      audit_events: Audit.prune(DateTime.add(now, -audit_days, :day)),
      deliveries: Integrations.prune_deliveries(DateTime.add(now, -deliveries_days, :day)),
      health_samples: RunnerTelemetry.prune_health(DateTime.add(now, -health_days, :day)),
      notifications:
        Notifications.delete_read_before(DateTime.add(now, -notifications_days, :day))
    }
    |> Map.merge(runner_logs(RunnerTelemetry.prune_logs(now)))
  end

  # The jobs past their workspace's retention of events, not pruned yet.
  defp prune_events(now, batch) do
    now = DateTime.truncate(now, :second)

    jobs =
      Repo.all(
        from j in Job,
          join: w in Workspace,
          on: w.id == j.workspace_id,
          where:
            is_nil(j.events_pruned_at) and not is_nil(j.finished_at) and
              j.finished_at <
                fragment(
                  "? - make_interval(days => ?)",
                  type(^now, :utc_datetime),
                  w.agent_events_retention_days
                ),
          select: {j, w.agent_events_after_retention},
          limit: ^batch
      )

    Enum.reduce(jobs, %{deleted: 0, stripped: 0, telemetry: 0}, fn {job, policy}, acc ->
      {:ok, counts} = Repo.transact(fn -> {:ok, prune_job(job, policy, now)} end)
      Map.merge(acc, counts, fn _key, a, b -> a + b end)
    end)
  end

  defp prune_job(job, policy, now) do
    # Its summary is written once more, final, from what is still whole; a
    # job the global retention of before already emptied keeps the one it has.
    if has_events_or_records?(job.id), do: Insights.store_summary(job)

    {telemetry, _} = Repo.delete_all(from t in Telemetry, where: t.job_id == ^job.id)
    {deleted, stripped} = prune_job_events(job.id, policy)

    {1, _} =
      Repo.update_all(from(j in Job, where: j.id == ^job.id), set: [events_pruned_at: now])

    %{deleted: deleted, stripped: stripped, telemetry: telemetry}
  end

  defp prune_job_events(job_id, :delete) do
    {deleted, _} = Repo.delete_all(from e in Event, where: e.job_id == ^job_id)
    {deleted, 0}
  end

  defp prune_job_events(job_id, :metadata) do
    keys = Event.metadata_keys()

    {stripped, _} =
      Repo.update_all(
        from(e in Event,
          where: e.job_id == ^job_id,
          update: [
            set: [
              data:
                fragment(
                  "(SELECT coalesce(jsonb_object_agg(k, v), '{}'::jsonb) FROM jsonb_each(?) AS kv(k, v) WHERE k = ANY(?))",
                  e.data,
                  type(^keys, {:array, :string})
                )
            ]
          ]
        ),
        []
      )

    {0, stripped}
  end

  defp has_events_or_records?(job_id) do
    Repo.exists?(from e in Event, where: e.job_id == ^job_id) or
      Repo.exists?(from t in Telemetry, where: t.job_id == ^job_id)
  end

  defp runner_logs(%{lines: lines, events: events}),
    do: %{runner_log_lines: lines, runner_events: events}

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
