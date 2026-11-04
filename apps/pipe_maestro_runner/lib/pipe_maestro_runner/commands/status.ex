defmodule PipeMaestroRunner.Commands.Status do
  @moduledoc """
  Shows the saved credentials and tries a connection to check them:

      pipemaestro status
  """

  alias PipeMaestroRunner.{Config, Connection, Host, Output}

  @timeout 10_000
  @spec run([String.t()]) :: any()
  def run(_args) do
    config = Output.config!()
    {:ok, hello} = Host.hello(labels: config.labels, capacity: config.capacity)

    Output.info("Versão: #{hello.runner_version}")

    Output.info("""
    Plataforma:  #{config.url}
    Runner:      #{config.runner_name} (#{config.runner_id})
    Workspace:   #{config.workspace_name} (/w/#{config.workspace_slug})
    Credenciais: #{Config.path()}
    """)

    {:ok, pid} = Connection.start_link(config: config, hello: hello, notify: self())

    receive do
      {:runner_connection, {:joined, _reply}} ->
        Output.info("Status: aceito pela plataforma.")

      {:runner_connection, :rejected} ->
        Output.error("Status: recusado (revogado). Rode pipemaestro login.")

      {:runner_connection, {:disconnected, reason}} ->
        Output.error("Status: sem conexão (#{inspect(reason)}).")
    after
      @timeout -> Output.error("Status: a plataforma não respondeu em #{@timeout} ms.")
    end

    if Process.alive?(pid), do: GenServer.stop(pid)
  end
end
