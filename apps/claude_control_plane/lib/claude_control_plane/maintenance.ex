defmodule ClaudeControlPlane.Maintenance do
  @moduledoc """
  Housekeeping that runs on its own, every `:every` ms (default one hour):

    * sign-in requests of runners (device flow) a day past their expiry go;
    * the events and the OpenTelemetry records of jobs that ended more than
      `:job_events_days` ago (default 30) go: the job keeps its outcome, cost,
      tokens, artifact and the totals of its run;
    * audit entries older than `:audit_days` (default 365) go.

  A process on each node of the control plane; with more than one node, a
  shared job queue would keep two from doing the same work.
  """
  use GenServer

  import Ecto.Query

  alias ClaudeControlPlane.{Audit, Repo}
  alias ClaudeControlPlane.Jobs.{Event, Job, Telemetry}
  alias ClaudeControlPlane.Runners.DeviceAuthorization

  @doc "Starts the periodic housekeeping. Options: `:every` (ms)."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Does the housekeeping once, as of `now`; returns how much each part removed."
  @spec run(DateTime.t(), keyword()) :: %{atom() => non_neg_integer()}
  def run(now, opts \\ []) do
    job_events_days = Keyword.get(opts, :job_events_days, 30)
    audit_days = Keyword.get(opts, :audit_days, 365)

    {device_authorizations, _} =
      Repo.delete_all(
        from a in DeviceAuthorization, where: a.expires_at < ^DateTime.add(now, -1, :day)
      )

    old_jobs =
      from j in Job,
        where: j.finished_at < ^DateTime.add(now, -job_events_days, :day),
        select: j.id

    {job_events, _} = Repo.delete_all(from e in Event, where: e.job_id in subquery(old_jobs))

    {job_telemetry, _} =
      Repo.delete_all(from t in Telemetry, where: t.job_id in subquery(old_jobs))

    %{
      device_authorizations: device_authorizations,
      job_events: job_events,
      job_telemetry: job_telemetry,
      audit_events: Audit.prune(DateTime.add(now, -audit_days, :day))
    }
  end

  @impl true
  def init(opts) do
    every = Keyword.get(opts, :every, :timer.hours(1))
    Process.send_after(self(), :run, every)
    {:ok, %{every: every, opts: opts}}
  end

  @impl true
  def handle_info(:run, state) do
    _removed = run(DateTime.utc_now(), state.opts)
    Process.send_after(self(), :run, state.every)
    {:noreply, state}
  end
end
