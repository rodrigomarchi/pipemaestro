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
    assert prepared.env["GIT_CONFIG_PARAMETERS"] =~ "'credential.https://forge.test.helper'=''"

    assert Enum.sort(Enum.map(GitCredential.git_env(prepared), &elem(&1, 0))) ==
             ~w(GIT_CONFIG_PARAMETERS PIPEMAESTRO_GIT_CREDENTIAL_FILE)

    assert GitCredential.prepare(%Job{id: "j2", prompt: "p"}, workdir).env == nil
  end

  test "the machine's own helpers are not asked nor told about the job's token", %{
    tmp_dir: workdir
  } do
    path = GitCredential.write(workdir, "j1", @credential)
    stored = Path.join(workdir, "guardado")
    global = Path.join(workdir, "gitconfig")

    File.write!(global, """
    [credential]
    \thelper = "!f() { echo username=da-maquina; echo password=da-maquina; }; f"
    \thelper = store --file #{stored}
    """)

    env = [
      {"GIT_CONFIG_GLOBAL", global},
      {"GIT_CONFIG_NOSYSTEM", "1"} | Enum.to_list(GitCredential.env(path, "forge.test"))
    ]

    request = "protocol=https\nhost=forge.test\n"

    {output, 0} =
      System.cmd("sh", ["-c", "printf '#{request}\n' | git credential fill"], env: env)

    assert output =~ "password=tok"

    {_, 0} =
      System.cmd(
        "sh",
        [
          "-c",
          "printf '#{request}username=pipemaestro-bot\npassword=tok\n\n' | git credential approve"
        ],
        env: env
      )

    refute File.exists?(stored)
  end

  test "the credential's password is a secret the changes may not carry", %{tmp_dir: workdir} do
    job =
      GitCredential.prepare(
        %Job{id: "j3", prompt: "p", env: %{"API" => "x"}, git_credential: @credential},
        workdir
      )

    assert {"git_credential", "tok"} in GitCredential.secrets(job)
    assert {"API", "x"} in GitCredential.secrets(job)
    # The helper's own variables are no secret to look for.
    refute Enum.any?(GitCredential.secrets(job), fn {name, _} ->
             String.starts_with?(name, "GIT_CONFIG")
           end)
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
