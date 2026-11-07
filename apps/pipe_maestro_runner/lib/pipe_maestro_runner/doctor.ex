defmodule PipeMaestroRunner.Doctor do
  @moduledoc """
  Checks that this machine can work as a runner (`mix runner.doctor`), after
  showing the runner's version: the agent CLI and how it signs in, git, the GitHub CLI (for pipelines that
  deliver a pull request), the saved credentials, the root and its
  directories, the free space for worktrees and whether the platform answers.

  Each check is `:ok`, a `:warning` (it runs, but something deserves a look) or
  an `:error` (jobs would fail), with what was found or what to do, and a
  stable `key` (`version`, `claude`, `auth`, `git`, `gh`, `config`,
  `directories`, `disk`, `platform`), by which the control plane follows a
  check from one run to the next (ADR 0039).
  """

  alias PipeMaestroRunner.{Claude, Config, Directories, Disk, Version}

  @type check :: %{
          key: String.t(),
          name: String.t(),
          status: :ok | :warning | :error,
          detail: String.t()
        }

  @low_disk_bytes 5 * 1024 * 1024 * 1024

  @doc """
  Runs every check. Options (for tests; each defaults to this machine's):
  `:config` (`Config.load/0`'s result), `:executable` (`Claude.executable/0`'s),
  `:workdir`, `:api_key` (`$RUNNER_ANTHROPIC_API_KEY`), `:gh` (the GitHub
  CLI's path, `nil` when there is none) and `:reach` (a function
  given the platform's health URL, returning `:ok` or `{:error, reason}`).
  """
  @spec run(keyword()) :: [check()]
  def run(opts \\ []) do
    config = Keyword.get_lazy(opts, :config, &Config.load/0)
    executable = Keyword.get_lazy(opts, :executable, &Claude.executable/0)
    workdir = Keyword.get_lazy(opts, :workdir, &Config.workdir/0)
    reach = Keyword.get(opts, :reach, &reach/1)
    agent = Claude.agent(executable, Keyword.get_lazy(opts, :api_key, &Claude.api_key/0))

    [
      check("version", "versão", :ok, Version.version()),
      agent_check(agent),
      auth_check(agent),
      git_check(),
      gh_check(
        Keyword.get_lazy(opts, :gh, fn ->
          System.get_env("GH_BIN") || System.find_executable("gh")
        end)
      ),
      config_check(config),
      directories_check(config),
      disk_check(workdir),
      platform_check(config, reach)
    ]
  end

  @doc "Whether no check found a problem (warnings are fine)."
  @spec ok?([check()]) :: boolean()
  def ok?(checks), do: Enum.all?(checks, &(&1.status != :error))

  defp agent_check(%{"cli_version" => nil}),
    do:
      check(
        "claude",
        "Agente (claude)",
        :error,
        "não encontrado: instale o claude ou defina CLAUDE_BIN"
      )

  defp agent_check(%{"cli_version" => version}),
    do: check("claude", "Agente (claude)", :ok, version)

  defp auth_check(%{"auth" => "api_key"}),
    do:
      check(
        "auth",
        "Credencial do agente",
        :ok,
        "chave de API do runner (RUNNER_ANTHROPIC_API_KEY)"
      )

  defp auth_check(_login),
    do:
      check(
        "auth",
        "Credencial do agente",
        :warning,
        "login pessoal de quem roda o claude; para uma chave própria, defina RUNNER_ANTHROPIC_API_KEY"
      )

  defp git_check do
    case System.find_executable("git") do
      nil ->
        check(
          "git",
          "git",
          :error,
          "não encontrado: as tarefas precisam de git para os worktrees"
        )

      git ->
        case System.cmd(git, ["--version"], stderr_to_stdout: true) do
          {version, 0} -> check("git", "git", :ok, String.trim(version))
          {output, _code} -> check("git", "git", :error, "não roda: #{String.trim(output)}")
        end
    end
  end

  defp gh_check(nil),
    do:
      check(
        "gh",
        "GitHub CLI (gh)",
        :warning,
        "não encontrado: só é preciso para pipelines com entrega em PR"
      )

  defp gh_check(gh) do
    case System.cmd(gh, ["auth", "status"], stderr_to_stdout: true) do
      {output, 0} ->
        lines = String.split(output, "\n", trim: true)
        signed_in = Enum.find(lines, List.first(lines, "ok"), &(&1 =~ "Logged in"))
        # gh marks the line with its own check mark.
        check(
          "gh",
          "GitHub CLI (gh)",
          :ok,
          signed_in |> String.trim() |> String.trim_leading("✓ ")
        )

      _not_signed_in ->
        check(
          "gh",
          "GitHub CLI (gh)",
          :warning,
          "sem login: rode gh auth login para pipelines com entrega em PR"
        )
    end
  end

  defp config_check({:ok, config}),
    do:
      check(
        "config",
        "Credenciais do runner",
        :ok,
        "#{config.runner_name} em #{config.workspace_name} (#{config.url})"
      )

  defp config_check({:error, :not_found}),
    do: check("config", "Credenciais do runner", :error, "nenhuma: rode pipemaestro login")

  defp config_check({:error, :invalid}),
    do:
      check(
        "config",
        "Credenciais do runner",
        :error,
        "#{Config.path()} é inválido: rode o login de novo"
      )

  defp directories_check({:ok, %{root: root}}) when is_binary(root) do
    case Directories.scan(root) do
      [] ->
        check(
          "directories",
          "Diretórios",
          :warning,
          "#{root} não tem subdiretórios para oferecer"
        )

      dirs ->
        git = Enum.count(dirs, & &1["git"])

        check(
          "directories",
          "Diretórios",
          :ok,
          "#{count(length(dirs), "diretório")} em #{root}, #{git} com git"
        )
    end
  end

  defp directories_check(_config),
    do:
      check(
        "directories",
        "Diretórios",
        :warning,
        "sem raiz: rode pipemaestro start --root ~/src para oferecer diretórios às tarefas"
      )

  defp disk_check(workdir) do
    File.mkdir_p!(workdir)
    usage = Disk.usage(workdir)
    worktrees = "#{count(usage["count"], "worktree")}"

    case usage["free_bytes"] do
      nil ->
        check("disk", "Disco", :warning, "#{worktrees}; espaço livre desconhecido")

      free when free < @low_disk_bytes ->
        check(
          "disk",
          "Disco",
          :warning,
          "#{worktrees}; pouco espaço livre (#{div(free, 1_048_576)} MB)"
        )

      free ->
        check("disk", "Disco", :ok, "#{worktrees}; #{div(free, 1_073_741_824)} GB livres")
    end
  end

  defp platform_check({:ok, config}, reach) do
    url = String.trim_trailing(config.url, "/") <> "/healthz"

    case reach.(url) do
      :ok -> check("platform", "Plataforma", :ok, "#{config.url} responde")
      {:error, reason} -> check("platform", "Plataforma", :error, "#{reason} (#{url})")
    end
  end

  defp platform_check(_no_config, _reach),
    do:
      check("platform", "Plataforma", :warning, "sem credenciais, não há plataforma para testar")

  defp reach(url) do
    case Req.get(url, retry: false, receive_timeout: 5_000) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: status}} -> {:error, "respondeu #{status}"}
      {:error, exception} -> {:error, Exception.message(exception)}
    end
  end

  defp count(1, noun), do: "1 #{noun}"
  defp count(n, noun), do: "#{n} #{noun}s"

  defp check(key, name, status, detail),
    do: %{key: key, name: name, status: status, detail: detail}
end
