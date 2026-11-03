defmodule ClaudeControlPlaneWeb.RunnerChannel do
  @moduledoc """
  One runner's channel (`runner:<id>`). Joining announces the runner
  (`ClaudeControlPlaneProtocol.Hello`): the details are stored and the runner
  is tracked as online in its workspace until the channel ends.
  """
  use Phoenix.Channel

  alias ClaudeControlPlane.Runners
  alias ClaudeControlPlaneProtocol.Hello
  alias ClaudeControlPlaneWeb.RunnerStatus

  @impl true
  def join("runner:" <> runner_id, payload, socket) do
    runner = socket.assigns.runner

    with true <- runner_id == runner.id,
         {:ok, hello} <- Hello.from_map(payload) do
      {:ok, runner} = Runners.record_hello(runner, hello)
      send(self(), :after_join)

      {:ok,
       %{"runner_id" => runner.id, "name" => runner.name, "workspace" => runner.workspace.name},
       assign(socket, runner: runner, joined: true)}
    else
      false -> {:error, %{"reason" => "unauthorized"}}
      {:error, reason} -> {:error, %{"reason" => "invalid_hello", "detail" => reason}}
    end
  end

  @impl true
  def handle_info(:after_join, socket) do
    runner = socket.assigns.runner
    {:ok, _ref} = RunnerStatus.track(self(), runner)
    RunnerStatus.notify_changed(runner.workspace_id)
    {:noreply, socket}
  end

  # Phoenix calls terminate after a refused join too; only a runner that was
  # actually online has a "last seen" to record.
  @impl true
  def terminate(_reason, %{assigns: %{joined: true, runner: runner}}) do
    Runners.touch_last_seen(runner)
    :ok
  end

  def terminate(_reason, _socket), do: :ok
end
