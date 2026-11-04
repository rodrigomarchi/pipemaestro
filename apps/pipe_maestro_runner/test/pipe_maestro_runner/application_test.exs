defmodule PipeMaestroRunner.ApplicationTest do
  use ExUnit.Case, async: true

  alias PipeMaestroRunner.Application, as: App

  test "as a library or a release run with eval, no command runs on its own" do
    assert App.standalone(%{}, run: fn _args -> flunk("ran") end) == :not_standalone
  end

  test "as a single binary, runs the command in the arguments, then halts with its status" do
    test_pid = self()

    App.standalone(%{"__BURRITO" => "1", "RELEASE_ROOT" => "/opt/burrito/x"},
      root_dir: fn -> "/opt/burrito/x" end,
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

  test "a VM that only inherited the single binary's variables runs no command" do
    env = %{"__BURRITO" => "1", "RELEASE_ROOT" => "/opt/burrito/x"}
    run = fn _args -> flunk("ran") end

    assert App.standalone(env, root_dir: fn -> "/usr/lib/erlang" end, run: run) ==
             :not_standalone

    assert App.standalone(Map.delete(env, "RELEASE_ROOT"), run: run) == :not_standalone
  end
end
