defmodule Mix.Tasks.Runner.Start do
  @shortdoc "Connects this runner to the platform and stays online"
  @moduledoc """
  Connects with the saved credentials and stays online until stopped (Ctrl+C):

      mix runner.start

  Reconnects on its own when the network drops. Stops when the platform
  refuses the runner (revoked), since retrying could not help.

  Runs the jobs the platform sends with the agent CLI (`claude`, or
  `$CLAUDE_BIN`), one at a time, in the runner's working directory (`workdir`
  next to the credentials). The agent runs with every permission granted.
  """
  use Mix.Task

  alias ClaudeControlPlaneRunner.{Claude, CLI, Config, Connection, Host}

  @impl Mix.Task
  def run(_args) do
    CLI.start!()
    config = CLI.config!()
    {:ok, hello} = Host.hello(labels: config.labels, capacity: config.capacity)

    workdir = Config.workdir()
    File.mkdir_p!(workdir)

    Mix.shell().info("""
    Workdir: #{workdir}
    Agente: #{agent_description()}
    Atenção: os jobs rodam o agente com permissões totais nesta máquina (sem container).
    """)

    Mix.shell().info("Conectando #{config.runner_name} a #{config.url}...")

    {:ok, pid} =
      Connection.start_link(config: config, hello: hello, notify: self(), workdir: workdir)

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

  defp agent_description do
    case Claude.executable() do
      {:ok, path} -> path
      {:error, :not_found} -> "não encontrado (instale o claude ou defina CLAUDE_BIN)"
    end
  end

  defp finished_label(%{"status" => "succeeded"} = payload) do
    cost = if payload["cost_usd"], do: ", US$ #{payload["cost_usd"]}", else: ""
    "concluído (#{payload["num_turns"] || 0} turnos#{cost})"
  end

  defp finished_label(%{"status" => "canceled"}), do: "cancelado"
  defp finished_label(payload), do: "falhou: #{payload["error"]}"
end
