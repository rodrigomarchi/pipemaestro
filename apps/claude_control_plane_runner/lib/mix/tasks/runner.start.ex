defmodule Mix.Tasks.Runner.Start do
  @shortdoc "Connects this runner to the platform and stays online"
  @moduledoc """
  Connects with the saved credentials and stays online until stopped (Ctrl+C):

      mix runner.start [--root ~/src]

  `--root` is where the code directories it offers are (every directory at its
  first level); it is saved with the credentials, so later starts reuse it.

  Reconnects on its own when the network drops. Stops when the platform
  refuses the runner (revoked), since retrying could not help.

  Runs the jobs the platform sends with the agent CLI (`claude`, or
  `$CLAUDE_BIN`), up to the runner's capacity at once
  (`ClaudeControlPlaneRunner.JobRunner`): a task's stages in a git worktree of
  the task's directory (`ClaudeControlPlaneRunner.Workspace`), a job on its own
  in the runner's working directory (`workdir` next to the credentials). The
  agent runs with the permission profile of each stage
  (`ClaudeControlPlaneRunner.Claude`).
  """
  use Mix.Task

  alias ClaudeControlPlaneRunner.{Claude, CLI, Config, Connection, Directories, Host}

  @switches [root: :string]

  @impl Mix.Task
  def run(args) do
    {opts, _rest, invalid} = OptionParser.parse(args, strict: @switches)
    if invalid != [], do: Mix.raise("Opção inválida: #{inspect(invalid)}")

    CLI.start!()
    config = config_with_root(CLI.config!(), opts[:root])
    agent = Claude.agent(Claude.executable())

    {:ok, hello} =
      Host.hello(labels: config.labels, capacity: config.capacity, agent: agent)

    workdir = Config.workdir()
    File.mkdir_p!(workdir)

    Mix.shell().info("""
    Workdir: #{workdir}
    Diretórios: #{root_description(config.root)}
    Capacidade: #{hello.capacity} jobs ao mesmo tempo
    Agente: #{agent_description()}
    Credencial: #{auth_description(agent)}
    Atenção: os jobs rodam nesta máquina, sem container, com o perfil de permissão de cada etapa (por padrão, total).
    """)

    Mix.shell().info("Conectando #{config.runner_name} a #{config.url}...")

    {:ok, pid} =
      Connection.start_link(
        config: config,
        hello: hello,
        notify: self(),
        workdir: workdir,
        root: config.root
      )

    ref = Process.monitor(pid)
    loop(config, ref)
  end

  defp loop(config, ref) do
    receive do
      {:runner_connection, {:joined, _reply}} ->
        Mix.shell().info(
          "Online como #{config.runner_name} no workspace #{config.workspace_name}."
        )

        loop(config, ref)

      {:runner_connection, {:job_started, job_id}} ->
        Mix.shell().info("Job #{job_id} iniciado.")
        loop(config, ref)

      {:runner_connection, {:job_finished, payload}} ->
        Mix.shell().info("Job #{payload["job_id"]} #{finished_label(payload)}.")
        loop(config, ref)

      {:runner_connection, {:disconnected, reason}} ->
        Mix.shell().info("Conexão perdida (#{inspect(reason)}). Reconectando...")
        loop(config, ref)

      {:runner_connection, :rejected} ->
        Mix.raise("""
        A plataforma recusou este runner: ele foi revogado ou a versão do protocolo
        não é mais aceita. Rode make runner.login para registrar de novo.
        """)

      {:DOWN, ^ref, :process, _pid, reason} ->
        Mix.raise("A conexão terminou: #{inspect(reason)}")
    end
  end

  defp config_with_root(config, nil), do: config

  defp config_with_root(config, root) do
    root = Path.expand(root)
    unless File.dir?(root), do: Mix.raise("O diretório raiz #{root} não existe.")

    config = Map.put(config, :root, root)
    Config.save(config)
    config
  end

  defp root_description(nil),
    do: "nenhum (rode com --root, ex.: make runner.start ROOT=~/src, para oferecer tarefas)"

  defp root_description(root), do: "#{root} (#{length(Directories.scan(root))} diretórios)"

  defp agent_description do
    case Claude.executable() do
      {:ok, path} -> path
      {:error, :not_found} -> "não encontrado (instale o claude ou defina CLAUDE_BIN)"
    end
  end

  defp auth_description(%{"auth" => "api_key"}),
    do: "chave de API do runner (RUNNER_ANTHROPIC_API_KEY)"

  defp auth_description(_login),
    do:
      "login pessoal do claude nesta máquina (defina RUNNER_ANTHROPIC_API_KEY para usar uma chave própria)"

  defp finished_label(%{"status" => "succeeded"} = payload) do
    cost = if payload["cost_usd"], do: ", US$ #{payload["cost_usd"]}", else: ""
    "concluído (#{payload["num_turns"] || 0} turnos#{cost})"
  end

  defp finished_label(%{"status" => "canceled"}), do: "cancelado"
  defp finished_label(payload), do: "falhou: #{payload["error"]}"
end
