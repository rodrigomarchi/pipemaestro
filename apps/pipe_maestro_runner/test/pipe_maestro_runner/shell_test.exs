defmodule PipeMaestroRunner.ShellTest do
  use ExUnit.Case, async: false

  alias PipeMaestroRunner.Shell

  @moduletag :tmp_dir

  test "runs the command in the directory, returning its status and output", %{tmp_dir: dir} do
    assert {3, output} = Shell.run(dir, "pwd; echo erro >&2; exit 3")
    assert output =~ Path.basename(dir)
    assert output =~ "erro"
  end

  test "the command does not inherit Burrito's __BURRITO", %{tmp_dir: dir} do
    previous = System.get_env("__BURRITO")
    System.put_env("__BURRITO", "1")

    on_exit(fn ->
      if previous, do: System.put_env("__BURRITO", previous), else: System.delete_env("__BURRITO")
    end)

    assert {0, "[]\n"} = Shell.run(dir, ~s(echo "[${__BURRITO-}]"))
  end
end
