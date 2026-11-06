defmodule PipeMaestroRunner.GitCredentialTest do
  use ExUnit.Case, async: true

  alias PipeMaestroProtocol.Job
  alias PipeMaestroRunner.GitCredential

  @moduletag :tmp_dir

  @credential %{"host" => "forge.test", "username" => "pipemaestro-bot", "password" => "tok"}

  test "writes the credential privately, rewrites it and removes it", %{tmp_dir: workdir} do
    path = GitCredential.write(workdir, "j1", @credential)

    assert File.read!(path) == "username=pipemaestro-bot\npassword=tok\n"
    assert File.stat!(path).mode |> Bitwise.band(0o777) == 0o600
    assert File.stat!(Path.dirname(path)).mode |> Bitwise.band(0o777) == 0o700

    GitCredential.write(workdir, "j1", %{@credential | "password" => "novo"})
    assert File.read!(path) =~ "password=novo"
    refute File.exists?(path <> ".tmp")

    assert GitCredential.remove(workdir, "j1") == :ok
    refute File.exists?(path)
  end

  test "clears what a stopped runner left", %{tmp_dir: workdir} do
    path = GitCredential.write(workdir, "j1", @credential)
    GitCredential.clear(workdir)
    refute File.exists?(path)
  end

  test "a job with a credential gets the variables git reads it by", %{tmp_dir: workdir} do
    job = %Job{id: "j1", prompt: "p", env: %{"OUTRO" => "x"}, git_credential: @credential}
    prepared = GitCredential.prepare(job, workdir)

    assert prepared.env["OUTRO"] == "x"
    assert prepared.env["PIPEMAESTRO_GIT_CREDENTIAL_FILE"] == GitCredential.path(workdir, "j1")
    assert prepared.env["GIT_CONFIG_KEY_0"] == "credential.https://forge.test.helper"

    assert Enum.sort(Enum.map(GitCredential.git_env(prepared), &elem(&1, 0))) ==
             ~w(GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_KEY_1 GIT_CONFIG_VALUE_0 GIT_CONFIG_VALUE_1 PIPEMAESTRO_GIT_CREDENTIAL_FILE)

    assert GitCredential.prepare(%Job{id: "j2", prompt: "p"}, workdir).env == nil
  end

  test "git asks the helper and gets the credential", %{tmp_dir: workdir} do
    path = GitCredential.write(workdir, "j1", @credential)
    env = GitCredential.env(path, "forge.test") |> Enum.to_list()

    {output, 0} =
      System.cmd(
        "sh",
        ["-c", "printf 'protocol=https\\nhost=forge.test\\n\\n' | git credential fill"],
        env: [
          {"GIT_CONFIG_GLOBAL", "/dev/null"},
          {"GIT_CONFIG_NOSYSTEM", "1"},
          {"GIT_TERMINAL_PROMPT", "0"} | env
        ]
      )

    assert output =~ "username=pipemaestro-bot"
    assert output =~ "password=tok"
  end
end
