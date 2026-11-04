defmodule PipeMaestroRunner.MainTest do
  # Main.run/1 points the commands' output at the terminal, a global setting.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias PipeMaestroRunner.{Main, Version}

  setup do
    previous = Application.get_env(:pipe_maestro_runner, :output)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:pipe_maestro_runner, :output, previous),
        else: Application.delete_env(:pipe_maestro_runner, :output)
    end)
  end

  test "--version and version print only the version and succeed" do
    for command <- ["--version", "version"] do
      output = capture_io(fn -> assert Main.run([command]) == 0 end)
      assert output == Version.version() <> "\n"
    end
  end

  test "the usage lists --version and --auto-update" do
    usage = capture_io(:stderr, fn -> assert Main.run([]) == 2 end)

    assert usage =~ "pipemaestro --version"
    assert usage =~ "pipemaestro login"
    assert usage =~ "--auto-update"
  end
end
