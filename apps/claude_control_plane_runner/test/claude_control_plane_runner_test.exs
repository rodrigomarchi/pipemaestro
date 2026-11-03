defmodule ClaudeControlPlaneRunnerTest do
  use ExUnit.Case, async: true

  test "announces the protocol version it was built with" do
    assert ClaudeControlPlaneRunner.protocol_version() == ClaudeControlPlaneProtocol.version()
  end
end
