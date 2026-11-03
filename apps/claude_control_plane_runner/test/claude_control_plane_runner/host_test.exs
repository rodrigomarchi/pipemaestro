defmodule ClaudeControlPlaneRunner.HostTest do
  use ExUnit.Case, async: true

  alias ClaudeControlPlaneRunner.{Connection, Host}

  test "describes this machine with extra labels and capacity" do
    assert {:ok, hello} = Host.hello(labels: ["GPU"], capacity: 3)

    assert hello.protocol_version == ClaudeControlPlaneProtocol.version()
    assert hello.hostname == Host.hostname()
    assert hello.os in ["linux", "macos", "windows"] or is_binary(hello.os)
    assert "gpu" in hello.labels
    assert Host.os() in hello.labels
    assert hello.capacity == 3
    assert Host.runner_version() =~ ~r/^\d+\.\d+\.\d+/
  end

  test "defaults the capacity to the scheduler count" do
    assert {:ok, %{capacity: capacity}} = Host.hello()
    assert capacity == System.schedulers_online()
  end

  test "builds the websocket URL from the platform URL" do
    assert Connection.websocket_url("http://localhost:4000", "cpr_x") ==
             "ws://localhost:4000/runner/socket/websocket?token=cpr_x&protocol_version=1"

    assert Connection.websocket_url("https://app.example.com", "cpr_x") =~
             "wss://app.example.com/runner/socket/websocket?"
  end
end
