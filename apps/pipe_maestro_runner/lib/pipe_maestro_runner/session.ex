defmodule PipeMaestroRunner.Session do
  @moduledoc """
  What `pipemaestro start` keeps running, under one supervisor:

    * a `PipeMaestroRunner.Outbox.Server`, holding what the control plane
      has not confirmed;
    * with a `:workdir`, the `PipeMaestroRunner.JobRunner`, reporting to it;
    * a `PipeMaestroRunner.Connection.Keeper`, starting the connection again
      when it crashes.

  So a connection that crashes takes neither the running jobs nor what they
  reported with it: the next one announces the jobs and sends it all again.
  The options are the connection's (`PipeMaestroRunner.Connection`). The
  outbox and the job runner are not started again: one of them ending ends
  the session.
  """
  use Supervisor

  alias PipeMaestroRunner.{Connection, JobRunner}
  alias PipeMaestroRunner.Connection.Keeper
  alias PipeMaestroRunner.Outbox.Server, as: OutboxServer

  @doc "Starts the session; `opts` are the connection's."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    with {:ok, session} <- Supervisor.start_link(__MODULE__, :ok),
         {:ok, outbox} <- start_child(session, {OutboxServer, path: opts[:outbox_path]}),
         {:ok, job_runner} <- start_job_runner(session, opts, outbox),
         {:ok, _keeper} <-
           start_child(session, {Keeper, opts ++ [outbox: outbox, job_runner: job_runner]}) do
      {:ok, session}
    end
  end

  defp start_child(session, spec) do
    case Supervisor.start_child(session, spec) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, reason} ->
        Supervisor.stop(session)
        {:error, reason}
    end
  end

  defp start_job_runner(session, opts, outbox) do
    case Keyword.fetch(opts, :workdir) do
      {:ok, workdir} ->
        start_child(session, {JobRunner, Connection.job_runner_opts(opts, workdir, outbox)})

      :error ->
        {:ok, nil}
    end
  end

  @doc "The connection running now, or `nil` while the keeper waits to start another."
  @spec connection(Supervisor.supervisor()) :: pid() | nil
  def connection(session), do: session |> child(Keeper) |> Keeper.connection()

  @doc "The session's job runner, or `nil` without a workdir."
  @spec job_runner(Supervisor.supervisor()) :: pid() | nil
  def job_runner(session), do: child(session, JobRunner)

  defp child(session, id) do
    Enum.find_value(Supervisor.which_children(session), fn
      {^id, pid, _type, _modules} when is_pid(pid) -> pid
      _other -> nil
    end)
  end

  @impl true
  def init(:ok), do: Supervisor.init([], strategy: :one_for_one, max_restarts: 0)
end
