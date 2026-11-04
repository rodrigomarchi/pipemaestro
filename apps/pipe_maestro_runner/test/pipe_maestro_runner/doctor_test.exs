defmodule PipeMaestroRunner.DoctorTest do
  use ExUnit.Case, async: true

  alias PipeMaestroRunner.Doctor

  @fake Path.expand("../support/fake_claude", __DIR__)

  @moduletag :tmp_dir

  defp config(attrs) do
    Map.merge(
      %{
        url: "http://127.0.0.1:9",
        runner_id: "r1",
        runner_name: "mac",
        token: "cpr_x",
        workspace_name: "Acme",
        workspace_slug: "acme",
        labels: [],
        capacity: nil,
        root: nil
      },
      attrs
    )
  end

  defp check(checks, name), do: Enum.find(checks, &(&1.name == name))

  test "reports each check: ok, a warning or a problem, with what to do", %{tmp_dir: dir} do
    root = Path.join(dir, "src")
    File.mkdir_p!(Path.join(root, "app"))

    checks =
      Doctor.run(
        config: {:ok, config(%{root: root})},
        executable: {:ok, @fake},
        api_key: nil,
        gh: nil,
        workdir: Path.join(dir, "workdir"),
        reach: fn _url -> {:error, "connection refused"} end
      )

    version = PipeMaestroRunner.Version.version()
    assert %{status: :ok, detail: ^version} = check(checks, "versão")
    assert %{status: :ok, detail: "0.0.0-fake" <> _} = check(checks, "Agente (claude)")

    assert %{status: :warning, detail: "login pessoal" <> _} =
             check(checks, "Credencial do agente")

    assert %{status: :ok} = check(checks, "git")
    assert %{status: :ok, detail: "mac em Acme" <> _} = check(checks, "Credenciais do runner")
    assert %{status: :ok, detail: detail} = check(checks, "Diretórios")
    assert detail =~ "1 diretório"
    assert %{status: :ok} = check(checks, "Disco")
    assert %{status: :error, detail: "connection refused" <> _} = check(checks, "Plataforma")
    assert %{status: :warning, detail: detail} = check(checks, "GitHub CLI (gh)")
    assert detail =~ "entrega em PR"
  end

  test "the GitHub CLI, when there is one, says whether it is signed in", %{tmp_dir: dir} do
    gh = Path.join(dir, "gh")
    File.write!(gh, "#!/bin/sh\necho 'Logged in to github.com account ana'\n")
    File.chmod!(gh, 0o755)

    checks =
      Doctor.run(
        config: {:error, :not_found},
        executable: {:ok, @fake},
        workdir: dir,
        gh: gh,
        reach: fn _url -> :ok end
      )

    assert %{status: :ok, detail: "Logged in to github.com account ana"} =
             check(checks, "GitHub CLI (gh)")

    File.write!(gh, "#!/bin/sh\necho 'You are not logged in' >&2; exit 1\n")

    checks =
      Doctor.run(
        config: {:error, :not_found},
        executable: {:ok, @fake},
        workdir: dir,
        gh: gh,
        reach: fn _ -> :ok end
      )

    assert %{status: :warning, detail: "sem login" <> _} = check(checks, "GitHub CLI (gh)")
  end

  test "a machine without the CLI, credentials or root says so", %{tmp_dir: dir} do
    checks =
      Doctor.run(
        config: {:error, :not_found},
        executable: {:error, :not_found},
        workdir: dir,
        reach: fn _url -> :ok end
      )

    assert %{status: :error} = check(checks, "Agente (claude)")
    assert %{status: :error, detail: detail} = check(checks, "Credenciais do runner")
    assert detail =~ "pipemaestro login"
    assert %{status: :warning} = check(checks, "Diretórios")
    assert check(checks, "Plataforma").status == :warning
    refute Doctor.ok?(checks)
  end

  test "the platform answers its health check", %{tmp_dir: dir} do
    checks =
      Doctor.run(
        config: {:ok, config(%{root: dir})},
        executable: {:ok, @fake},
        workdir: dir,
        reach: fn "http://127.0.0.1:9/healthz" -> :ok end
      )

    assert %{status: :ok} = check(checks, "Plataforma")
  end
end
