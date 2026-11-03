defmodule Mix.Tasks.RunnerTasksTest do
  use ExUnit.Case, async: false

  alias ClaudeControlPlaneRunner.Config
  alias Mix.Tasks.Runner.{Login, Logout, Start, Status}

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    previous = System.get_env("RUNNER_CONFIG_DIR")
    System.put_env("RUNNER_CONFIG_DIR", dir)
    Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      Mix.shell(Mix.Shell.IO)

      if previous,
        do: System.put_env("RUNNER_CONFIG_DIR", previous),
        else: System.delete_env("RUNNER_CONFIG_DIR")
    end)

    %{dir: dir}
  end

  test "login needs the platform URL and valid options" do
    assert_raise Mix.Error, ~r/--url/, fn -> Login.run([]) end
    assert_raise Mix.Error, ~r/Opção inválida/, fn -> Login.run(["--nope"]) end
  end

  test "login reports an unreachable platform" do
    assert_raise Mix.Error, ~r/Não foi possível falar com/, fn ->
      Login.run(["--url", "http://127.0.0.1:1"])
    end
  end

  test "start and status tell what to do without credentials" do
    assert_raise Mix.Error, ~r/ainda não fez login/, fn -> Start.run([]) end
    assert_raise Mix.Error, ~r/ainda não fez login/, fn -> Status.run([]) end
  end

  test "start reports corrupt credentials", %{dir: dir} do
    File.write!(Config.path(dir), "not json")
    assert_raise Mix.Error, ~r/corrompidas/, fn -> Start.run([]) end
  end

  test "logout removes the credentials", %{dir: dir} do
    File.write!(Config.path(dir), "{}")
    Logout.run([])

    refute File.exists?(Config.path(dir))
    assert_received {:mix_shell, :info, [message]}
    assert message =~ "Credenciais removidas"
  end
end
