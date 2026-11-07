defmodule PipeMaestroRunner.Outbox.Server do
  @moduledoc """
  Holds the runner's `PipeMaestroRunner.Outbox` apart from the connection,
  so what was not confirmed outlives a connection that crashes.

  It is the owner of the `PipeMaestroRunner.JobRunner`: each
  `{:job_out, event, payload}` is added to the outbox and passed on to the
  connection registered (`register/2`) as `{:outbox_out, id, event,
  payload}`; with none, it waits in the outbox for the next join. What the
  agent is writing (`{:job_live, event, payload}`) is passed on as is, or
  dropped with no connection.

  The connection tells it what it pushed (`sent/3`) and what the control
  plane confirmed (`confirmed/2`), and on every join takes what is still to
  confirm (`joined/1`).
  """
  use GenServer

  alias PipeMaestroRunner.Outbox

  @doc """
  Starts the server. Options: `:path` (the outbox's file, `Outbox.new/2`),
  `:max` (messages it holds, default 20 000).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "`pid` is the connection now: what the job runner reports goes to it."
  @spec register(GenServer.server(), pid()) :: :ok
  def register(server, pid), do: GenServer.call(server, {:register, pid})

  @doc "Adds a message the caller pushes itself; returns its id, for `sent/3`."
  @spec add(GenServer.server(), String.t(), map()) :: non_neg_integer()
  def add(server, event, payload), do: GenServer.call(server, {:add, event, payload})

  @doc """
  A new join: no reply to an earlier push will come. Returns the messages
  still to confirm, oldest first, to send again.
  """
  @spec joined(GenServer.server()) :: [{non_neg_integer(), String.t(), map()}]
  def joined(server), do: GenServer.call(server, :joined)

  @doc "The message `id` was pushed and `ref` will carry its reply."
  @spec sent(GenServer.server(), non_neg_integer(), term()) :: :ok
  def sent(server, id, ref), do: GenServer.cast(server, {:sent, id, ref})

  @doc "The reply to `ref` arrived: its message is done."
  @spec confirmed(GenServer.server(), term()) :: :ok
  def confirmed(server, ref), do: GenServer.cast(server, {:confirmed, ref})

  @doc "The jobs with messages still to confirm."
  @spec job_ids(GenServer.server()) :: [String.t()]
  def job_ids(server), do: GenServer.call(server, {:read, &Outbox.job_ids/1})

  @doc "The jobs whose end is still to confirm (`Outbox.finished_job_ids/1`)."
  @spec finished_job_ids(GenServer.server()) :: [String.t()]
  def finished_job_ids(server), do: GenServer.call(server, {:read, &Outbox.finished_job_ids/1})

  @doc "How many messages are still to confirm."
  @spec size(GenServer.server()) :: non_neg_integer()
  def size(server), do: GenServer.call(server, {:read, &Outbox.size/1})

  @doc "How many messages it dropped for lack of room."
  @spec dropped(GenServer.server()) :: non_neg_integer()
  def dropped(server), do: GenServer.call(server, {:read, &Outbox.dropped/1})

  @doc "Writes everything still to confirm to the file (`Outbox.persist_all/1`)."
  @spec persist_all(GenServer.server()) :: :ok
  def persist_all(server), do: GenServer.call(server, {:read, &Outbox.persist_all/1})

  @impl true
  def init(opts) do
    outbox = Outbox.new(Keyword.get(opts, :max, 20_000), Keyword.get(opts, :path))
    {:ok, %{outbox: outbox, connection: nil, monitor: nil}}
  end

  @impl true
  def handle_call({:register, pid}, _from, state) do
    if state.monitor, do: Process.demonitor(state.monitor, [:flush])
    {:reply, :ok, %{state | connection: pid, monitor: Process.monitor(pid)}}
  end

  def handle_call({:add, event, payload}, _from, state) do
    {id, outbox} = Outbox.add(state.outbox, event, payload)
    {:reply, id, %{state | outbox: outbox}}
  end

  def handle_call(:joined, _from, state) do
    outbox = Outbox.forget_refs(state.outbox)
    {:reply, Outbox.pending(outbox), %{state | outbox: outbox}}
  end

  def handle_call({:read, fun}, _from, state), do: {:reply, fun.(state.outbox), state}

  @impl true
  def handle_cast({:sent, id, ref}, state),
    do: {:noreply, %{state | outbox: Outbox.sent(state.outbox, id, ref)}}

  def handle_cast({:confirmed, ref}, state),
    do: {:noreply, %{state | outbox: Outbox.confirmed(state.outbox, ref)}}

  @impl true
  def handle_info({:job_out, event, payload}, state) do
    {id, outbox} = Outbox.add(state.outbox, event, payload)
    if state.connection, do: send(state.connection, {:outbox_out, id, event, payload})
    {:noreply, %{state | outbox: outbox}}
  end

  def handle_info({:job_live, _event, _payload} = message, state) do
    if state.connection, do: send(state.connection, message)
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{monitor: ref} = state),
    do: {:noreply, %{state | connection: nil, monitor: nil}}
end
