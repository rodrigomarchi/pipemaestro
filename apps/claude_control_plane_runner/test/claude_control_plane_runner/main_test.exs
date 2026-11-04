defmodule ClaudeControlPlaneRunner.MainTest do
  # Main.run/1 points the commands' output at the terminal, a global setting.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias ClaudeControlPlaneRunner.{Main, Version}

  setup do
    previous = Application.get_env(:claude_control_plane_runner, :output)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:claude_control_plane_runner, :output, previous),
        else: Application.delete_env(:claude_control_plane_runner, :output)
    end)
  end

  test "--version and version print only the version and succeed" do
    for command <- ["--version", "version"] do
      output = capture_io(fn -> assert Main.run([command]) == 0 end)
      assert output == Version.version() <> "\n"
    end
  end

  test "the usage lists --version" do
    usage = capture_io(:stderr, fn -> assert Main.run([]) == 2 end)

    assert usage =~ "cp-runner --version"
    assert usage =~ "cp-runner login"
  end
end
