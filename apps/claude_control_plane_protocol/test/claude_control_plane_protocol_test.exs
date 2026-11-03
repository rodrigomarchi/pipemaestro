defmodule ClaudeControlPlaneProtocolTest do
  use ExUnit.Case, async: true

  test "speaks a positive protocol version" do
    assert ClaudeControlPlaneProtocol.version() >= 1
  end
end
