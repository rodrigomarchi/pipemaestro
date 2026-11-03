defmodule Mix.Tasks.Runner.Status do
  @shortdoc "Shows this runner's credentials and whether the platform accepts them"
  @moduledoc """
  Shows the saved credentials and tries a connection to check them:

      mix runner.status
  """
  use Mix.Task

  alias ClaudeControlPlaneRunner.{CLI, Config, Connection, Host}

  @timeout 10_000

  @impl Mix.Task
  def run(_args) do
    CLI.start!()
    config = CLI.config!()
    {:ok, hello} = Host.hello(labels: config.labels, capacity: config.capacity)

    Mix.shell().info("""
    Plataforma:  #{config.url}
    Runner:      #{config.runner_name} (#{config.runner_id})
    Workspace:   #{config.workspace_name} (/w/#{config.workspace_slug})
    Credenciais: #{Config.path()}
    """)

    {:ok, pid} = Connection.start_link(config: config, hello: hello, notify: self())

    receive do
      {:runner_connection, {:joined, _reply}} ->
        Mix.shell().info("Status: aceito pela plataforma.")

      {:runner_connection, :rejected} ->
        Mix.shell().error("Status: recusado (revogado). Rode make runner.login.")

      {:runner_connection, {:disconnected, reason}} ->
        Mix.shell().error("Status: sem conexão (#{inspect(reason)}).")
    after
      @timeout -> Mix.shell().error("Status: a plataforma não respondeu em #{@timeout} ms.")
    end

    if Process.alive?(pid), do: GenServer.stop(pid)
  end
end
