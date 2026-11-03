defmodule ClaudeControlPlaneWeb.RunnerChannelTest do
  use ClaudeControlPlaneWeb.ChannelCase, async: false

  alias ClaudeControlPlane.Runners
  alias ClaudeControlPlaneProtocol.Hello
  alias ClaudeControlPlaneWeb.{RunnerChannel, RunnerSocket, RunnerStatus}

  setup do
    workspace = workspace_fixture()
    user = member_fixture(workspace)
    {runner, token} = runner_fixture(workspace, user, %{name: "build-01"})
    %{workspace: workspace, runner: runner, token: token}
  end

  defp params(token, version \\ ClaudeControlPlaneProtocol.version()) do
    %{"token" => token, "protocol_version" => to_string(version)}
  end

  describe "connect" do
    test "accepts the runner's token", %{runner: runner, token: token} do
      assert {:ok, socket} = connect(RunnerSocket, params(token))
      assert socket.assigns.runner.id == runner.id
      assert RunnerSocket.id(socket) == "runner_socket:" <> runner.id
    end

    test "refuses a wrong token, a revoked runner or an unsupported version", %{
      runner: runner,
      token: token
    } do
      assert connect(RunnerSocket, params("cpr_wrong")) == :error
      assert connect(RunnerSocket, params(token, 999)) == :error
      assert connect(RunnerSocket, params(token, "abc")) == :error
      assert connect(RunnerSocket, %{}) == :error

      {:ok, _} = Runners.revoke_runner(runner)
      assert connect(RunnerSocket, params(token)) == :error
    end
  end

  describe "join" do
    setup %{token: token} do
      {:ok, socket} = connect(RunnerSocket, params(token))
      %{socket: socket}
    end

    test "records the hello and tracks the runner online until it leaves", %{
      socket: socket,
      runner: runner,
      workspace: workspace
    } do
      RunnerStatus.subscribe(workspace.id)
      hello = hello_fixture(%{labels: ["docker", "linux"], capacity: 8})

      {:ok, reply, channel} =
        subscribe_and_join(socket, RunnerChannel, "runner:" <> runner.id, Hello.to_map(hello))

      assert reply["name"] == "build-01"
      assert_receive :runners_changed
      assert MapSet.member?(RunnerStatus.online_ids(workspace.id), runner.id)

      assert %{labels: ["docker", "linux"], capacity: 8} =
               Runners.get_runner!(workspace, runner.id)

      Process.unlink(channel.channel_pid)
      ref = Process.monitor(channel.channel_pid)
      close(channel)
      assert_receive {:DOWN, ^ref, _, _, _}
      assert_receive %Phoenix.Socket.Broadcast{event: "presence_diff"}
      refute MapSet.member?(RunnerStatus.online_ids(workspace.id), runner.id)
    end

    test "refuses another runner's topic or an invalid hello", %{socket: socket, runner: runner} do
      hello = Hello.to_map(hello_fixture())

      assert {:error, %{"reason" => "unauthorized"}} =
               subscribe_and_join(socket, RunnerChannel, "runner:someone-else", hello)

      assert {:error, %{"reason" => "invalid_hello"}} =
               subscribe_and_join(socket, RunnerChannel, "runner:" <> runner.id, %{})
    end

    test "revoking tells the runner's socket to disconnect", %{
      socket: socket,
      runner: runner,
      workspace: workspace
    } do
      RunnerStatus.subscribe(workspace.id)

      {:ok, _reply, channel} =
        subscribe_and_join(
          socket,
          RunnerChannel,
          "runner:" <> runner.id,
          Hello.to_map(hello_fixture())
        )

      # The channel finishes joining (tracking, notifying) before it is closed.
      assert_receive :runners_changed

      @endpoint.subscribe(RunnerStatus.socket_id(runner.id))
      RunnerStatus.disconnect(runner)
      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}

      Process.unlink(channel.channel_pid)
      ref = Process.monitor(channel.channel_pid)
      close(channel)
      assert_receive {:DOWN, ^ref, _, _, _}
    end
  end
end
