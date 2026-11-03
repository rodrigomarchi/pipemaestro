defmodule ClaudeControlPlaneRunner.ApplicationTest do
  use ExUnit.Case, async: true

  alias ClaudeControlPlaneRunner.Application, as: App

  test "as a library or a release run with eval, no command runs on its own" do
    assert App.standalone(%{}, run: fn _args -> flunk("ran") end) == :not_standalone
  end

  test "as a single binary, runs the command in the arguments, then halts with its status" do
    test_pid = self()

    App.standalone(%{"__BURRITO" => "1"},
      argv: fn -> [~c"status"] end,
      run: fn args ->
        send(test_pid, {:ran, args})
        3
      end,
      halt: fn status -> send(test_pid, {:halted, status}) end
    )

    assert_received {:ran, ["status"]}
    assert_received {:halted, 3}
  end
end
