defmodule ClaudeControlPlaneWeb.RunnerStatus do
  @moduledoc """
  Live runner status for the screens: who is online in a workspace, and the
  notifications that make every open screen reload its runners.

  Screens subscribe to the workspace topic and receive two messages: the
  presence diff (`%Phoenix.Socket.Broadcast{event: "presence_diff"}`) when a
  runner connects or drops, and `:runners_changed` when one is renamed,
  revoked or announces new details.
  """

  alias ClaudeControlPlane.Runners.Runner
  alias ClaudeControlPlaneWeb.RunnerPresence

  @doc "The PubSub topic of a workspace's runners."
  @spec topic(Ecto.UUID.t()) :: String.t()
  def topic(workspace_id), do: "workspace_runners:" <> workspace_id

  @doc "Subscribes the caller to a workspace's runner updates."
  @spec subscribe(Ecto.UUID.t()) :: :ok
  def subscribe(workspace_id) do
    Phoenix.PubSub.subscribe(ClaudeControlPlane.PubSub, topic(workspace_id))
  end

  @doc "Ids of the workspace's runners connected right now."
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
    Phoenix.PubSub.broadcast(ClaudeControlPlane.PubSub, topic(workspace_id), :runners_changed)
  end

  @doc "Closes the runner's open connection, if it has one."
  @spec disconnect(Runner.t()) :: :ok
  def disconnect(%Runner{id: id}) do
    ClaudeControlPlaneWeb.Endpoint.broadcast(socket_id(id), "disconnect", %{})
  end

  @doc "The socket id of a runner's connection."
  @spec socket_id(Ecto.UUID.t()) :: String.t()
  def socket_id(runner_id), do: "runner_socket:" <> runner_id
end
