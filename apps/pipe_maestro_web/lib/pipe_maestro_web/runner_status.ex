defmodule PipeMaestroWeb.RunnerStatus do
  @moduledoc """
  Live runner status for the screens: who is online in a workspace, and the
  notifications that make every open screen reload its runners and the
  alerts that depend on them.

  Screens subscribe to the workspace topic and receive two messages: the
  presence diff (`%Phoenix.Socket.Broadcast{event: "presence_diff"}`) when a
  runner connects or drops, and `:runners_changed` when one is renamed,
  revoked or announces new details.

  It is also the domain's `PipeMaestro.Runners.Presence`.
  """

  @behaviour PipeMaestro.Runners.Presence

  alias PipeMaestro.Runners.Runner
  alias PipeMaestroWeb.RunnerPresence

  @doc "The PubSub topic of a workspace's runners."
  @spec topic(Ecto.UUID.t()) :: String.t()
  def topic(workspace_id), do: "workspace_runners:" <> workspace_id

  @doc "Subscribes the caller to a workspace's runner updates."
  @spec subscribe(Ecto.UUID.t()) :: :ok
  def subscribe(workspace_id) do
    Phoenix.PubSub.subscribe(PipeMaestro.PubSub, topic(workspace_id))
  end

  @doc "Ids of the workspace's runners connected right now."
  @impl PipeMaestro.Runners.Presence
  @spec online_ids(Ecto.UUID.t()) :: MapSet.t(String.t())
  def online_ids(workspace_id) do
    workspace_id |> topic() |> RunnerPresence.list() |> Map.keys() |> MapSet.new()
  end

  @doc "Marks `runner` online for as long as the calling process lives."
  @spec track(pid(), Runner.t()) :: {:ok, binary()} | {:error, term()}
  def track(pid, %Runner{} = runner) do
    RunnerPresence.track(pid, topic(runner.workspace_id), runner.id, %{
      connected_at: System.system_time(:second)
    })
  end

  @doc "Tells every open screen of the workspace to reload its runners."
  @spec notify_changed(Ecto.UUID.t()) :: :ok
  def notify_changed(workspace_id) do
    Phoenix.PubSub.broadcast(PipeMaestro.PubSub, topic(workspace_id), :runners_changed)
  end

  @doc "The PubSub topic of one runner's telemetry (ADR 0039)."
  @spec telemetry_topic(Ecto.UUID.t()) :: String.t()
  def telemetry_topic(runner_id), do: "runner_telemetry:" <> runner_id

  @doc """
  Subscribes the caller to one runner's telemetry: it receives
  `{:runner_telemetry, kind}` (`:health`, `:log`, `:doctor`) when the runner
  reports something new.
  """
  @spec subscribe_telemetry(Ecto.UUID.t()) :: :ok
  def subscribe_telemetry(runner_id),
    do: Phoenix.PubSub.subscribe(PipeMaestro.PubSub, telemetry_topic(runner_id))

  @doc "Tells the screens following a runner that it reported `kind` of telemetry."
  @spec notify_telemetry(Ecto.UUID.t(), atom()) :: :ok
  def notify_telemetry(runner_id, kind),
    do:
      Phoenix.PubSub.broadcast(
        PipeMaestro.PubSub,
        telemetry_topic(runner_id),
        {:runner_telemetry, kind}
      )

  @doc "The PubSub topic of what the screens ask of a runner's channel."
  @spec commands_topic(Ecto.UUID.t()) :: String.t()
  def commands_topic(runner_id), do: "runner_commands:" <> runner_id

  @doc "Subscribes the caller (a runner's channel) to what the screens ask of it."
  @spec subscribe_commands(Ecto.UUID.t()) :: :ok
  def subscribe_commands(runner_id),
    do: Phoenix.PubSub.subscribe(PipeMaestro.PubSub, commands_topic(runner_id))

  @doc """
  Asks the runner, through its open channel, to run its diagnosis now.
  Returns the request's id, which the answer carries.
  """
  @spec request_doctor(Ecto.UUID.t()) :: String.t()
  def request_doctor(runner_id) do
    request_id = Ecto.UUID.generate()

    Phoenix.PubSub.broadcast(
      PipeMaestro.PubSub,
      commands_topic(runner_id),
      {:doctor_request, request_id}
    )

    request_id
  end

  @doc "Closes the runner's open connection, if it has one."
  @spec disconnect(Runner.t()) :: :ok
  def disconnect(%Runner{id: id}) do
    PipeMaestroWeb.Endpoint.broadcast(socket_id(id), "disconnect", %{})
  end

  @doc "The socket id of a runner's connection."
  @spec socket_id(Ecto.UUID.t()) :: String.t()
  def socket_id(runner_id), do: "runner_socket:" <> runner_id
end
