defmodule PipeMaestroRunner.Commands.Start do
  @moduledoc """
  Connects with the saved credentials and stays online until stopped (Ctrl+C):

      pipemaestro start [--root ~/src] [--auto-update]

  `--root` is where the code directories it offers are (every directory at its
  first level); it is saved with the credentials, so later starts reuse it.

  Reconnects on its own when the network drops. Stops when the platform
  refuses the runner (revoked), since retrying could not help. Refused for
  not being on the platform's version, the single binary offers to update
  itself and start again (`PipeMaestroRunner.Update`); `--auto-update` does it
  without asking, as the service does.

  Runs the jobs the platform sends with the agent CLI (`claude`, or
  `$CLAUDE_BIN`), up to the runner's capacity at once
  (`PipeMaestroRunner.JobRunner`): a task's stages in a git worktree of
  the task's directory (`PipeMaestroRunner.Workspace`), a job on its own
  in the runner's working directory (`workdir` next to the credentials). The
  agent runs with the permission profile of each stage
  (`PipeMaestroRunner.Claude`).
  """

  alias PipeMaestroRunner.{
    Claude,
    Config,
    Connection,
    Directories,
    Host,
    Output,
    SelfUpdate,
    Update
  }

  @switches [root: :string, auto_update: :boolean]
  @spec run([String.t()]) :: no_return()
  def run(args) do
    {opts, _rest, invalid} = OptionParser.parse(args, strict: @switches)
    if invalid != [], do: Output.fail!("Opção inválida: #{inspect(invalid)}")

    Output.info("pipemaestro #{Host.runner_version()}")
    if bin = System.get_env("__BURRITO_BIN_PATH"), do: SelfUpdate.clean_stale(bin)
    config = config_with_root(Output.config!(), opts[:root])
    agent = Claude.agent(Claude.executable())

    {:ok, hello} =
      Host.hello(labels: config.labels, capacity: config.capacity, agent: agent)

    workdir = Config.workdir()
    File.mkdir_p!(workdir)

    Output.info("""
    Workdir: #{workdir}
    Diretórios: #{root_description(config.root)}
    Capacidade: #{hello.capacity} jobs ao mesmo tempo
    Agente: #{agent_description()}
    Credencial: #{auth_description(agent)}
    Atenção: os jobs rodam nesta máquina, sem container, com todas as permissões do agente: os pipelines seguem sozinhos.
    """)

    Output.info("Conectando #{config.runner_name} a #{config.url}...")

    {:ok, pid} =
      Connection.start_link(
        config: config,
        hello: hello,
        notify: self(),
        workdir: workdir,
        outbox_path: Path.join(Config.dir(), "outbox.bin"),
        root: config.root,
        # The CLI's OpenTelemetry, received on this machine and relayed.
        telemetry: true
      )

    ref = Process.monitor(pid)
    update = [argv: ["start" | args], auto_update: opts[:auto_update], platform_url: config.url]
    loop(config, ref, update)
  end

  defp loop(config, ref, update) do
    receive do
      {:runner_connection, {:joined, _reply}} ->
        Output.info("Online como #{config.runner_name} no workspace #{config.workspace_name}.")

        loop(config, ref, update)

      {:runner_connection, {:job_started, job_id}} ->
        Output.info("Job #{job_id} iniciado.")
        loop(config, ref, update)

      {:runner_connection, {:job_finished, payload}} ->
        Output.info("Job #{payload["job_id"]} #{finished_label(payload)}.")
        loop(config, ref, update)

      {:runner_connection, {:disconnected, reason}} ->
        Output.info("Conexão perdida (#{inspect(reason)}). Reconectando...")
        loop(config, ref, update)

      {:runner_connection, {:outdated, refusal}} ->
        {:fail, message} = Update.handle(refusal, update)
        Output.fail!(message)

      {:runner_connection, :rejected} ->
        Output.fail!("""
        A plataforma recusou este runner: ele foi revogado ou a versão do protocolo
        não é mais aceita. Rode pipemaestro login (ou make runner.login) para registrar de novo.
        """)

      {:DOWN, ^ref, :process, _pid, reason} ->
        Output.fail!("A conexão terminou: #{inspect(reason)}")
    end
  end

  defp config_with_root(config, nil), do: config

  defp config_with_root(config, root) do
    root = Path.expand(root)
    unless File.dir?(root), do: Output.fail!("O diretório raiz #{root} não existe.")

    config = Map.put(config, :root, root)
    Config.save(config)
    config
  end

  defp root_description(nil),
    do: "nenhum (rode com --root ~/src para oferecer tarefas)"

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
