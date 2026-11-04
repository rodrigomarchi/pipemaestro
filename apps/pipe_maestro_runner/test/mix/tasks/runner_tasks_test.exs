defmodule Mix.Tasks.RunnerTasksTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Runner.{Login, Logout, Start, Status}
  alias Mix.Tasks.Runner.Version, as: RunnerVersion
  alias PipeMaestroRunner.{Config, Version}

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

  test "login rejects invalid options" do
    assert_raise Mix.Error, ~r/Opção inválida/, fn -> Login.run(["--nope"]) end
  end

  test "login without --url signs in to the default platform" do
    with_url_env("http://127.0.0.1:1", fn ->
      assert_raise Mix.Error, ~r{Não foi possível falar com http://127.0.0.1:1}, fn ->
        Login.run([])
      end
    end)
  end

  test "the default platform is production unless PIPEMAESTRO_URL names another" do
    with_url_env(nil, fn -> assert Config.default_url() == "https://pipemaestro.app" end)
    with_url_env("", fn -> assert Config.default_url() == "https://pipemaestro.app" end)

    with_url_env("http://localhost:4000", fn ->
      assert Config.default_url() == "http://localhost:4000"
    end)
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

  test "start and login take --auto-update" do
    assert_raise Mix.Error, ~r/ainda não fez login/, fn -> Start.run(["--auto-update"]) end

    assert_raise Mix.Error, ~r/Não foi possível falar com/, fn ->
      Login.run(["--auto-update", "--url", "http://127.0.0.1:1"])
    end
  end

  test "start reports corrupt credentials", %{dir: dir} do
    File.write!(Config.path(dir), "not json")
    assert_raise Mix.Error, ~r/corrompidas/, fn -> Start.run([]) end
  end

  defp save_config(attrs \\ %{}) do
    Config.save(
      Map.merge(
        %{
          url: "http://127.0.0.1:1",
          runner_id: "r1",
          runner_name: "mac",
          token: "cpr_x",
          workspace_name: "Acme",
          workspace_slug: "acme",
          labels: [],
          capacity: 1,
          root: nil
        },
        attrs
      )
    )
  end

  test "version prints only the runner's version" do
    RunnerVersion.run([])

    assert_received {:mix_shell, :info, [output]}
    assert output == Version.version()
  end

  test "version --next prints the next release, in the release scheme" do
    RunnerVersion.run(["--next"])

    assert_received {:mix_shell, :info, [output]}
    assert {:release, _date, _number} = PipeMaestroProtocol.Version.parse(output)
  end

  test "start shows the version on its first line", %{dir: dir} do
    save_config()

    assert_raise Mix.Error, ~r/não existe/, fn ->
      Start.run(["--root", Path.join(dir, "missing")])
    end

    assert_received {:mix_shell, :info, [first]}
    assert first == "pipemaestro #{Version.version()}"
  end

  test "status shows the version" do
    save_config()
    Status.run([])

    assert_received {:mix_shell, :info, [summary]}
    assert summary =~ "Versão: #{Version.version()}"
  end

  test "logout removes the credentials", %{dir: dir} do
    File.write!(Config.path(dir), "{}")
    Logout.run([])

    refute File.exists?(Config.path(dir))
    assert_received {:mix_shell, :info, [message]}
    assert message =~ "Credenciais removidas"
  end

  defp with_url_env(value, fun) do
    previous = System.get_env("PIPEMAESTRO_URL")

    if value,
      do: System.put_env("PIPEMAESTRO_URL", value),
      else: System.delete_env("PIPEMAESTRO_URL")

    try do
      fun.()
    after
      if previous,
        do: System.put_env("PIPEMAESTRO_URL", previous),
        else: System.delete_env("PIPEMAESTRO_URL")
    end
  end
end
