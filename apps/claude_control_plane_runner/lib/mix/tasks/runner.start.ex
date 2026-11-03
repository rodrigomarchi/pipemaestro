defmodule Mix.Tasks.Runner.Start do
  @shortdoc "Connects this runner to the platform and stays online"
  @moduledoc """
  Connects with the saved credentials and stays online until stopped (Ctrl+C):

      mix runner.start

  Reconnects on its own when the network drops. Stops when the platform
  refuses the runner (revoked), since retrying could not help.
  """
  use Mix.Task

  alias ClaudeControlPlaneRunner.{CLI, Connection, Host}

  @impl Mix.Task
  def run(_args) do
    CLI.start!()
    config = CLI.config!()
    {:ok, hello} = Host.hello(labels: config.labels, capacity: config.capacity)

    Mix.shell().info("Conectando #{config.runner_name} a #{config.url}...")

    {:ok, pid} = Connection.start_link(config: config, hello: hello, notify: self())
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
end
