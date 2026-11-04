defmodule Mix.Tasks.Runner.Service do
  @shortdoc "Installs, removes or shows the runner as a background service"
  @moduledoc """
  Runs the runner in the background as a service of the current user
  (`PipeMaestroRunner.Service`): a launchd agent on macOS, a systemd
  user unit on Linux. It uses the saved credentials and root, so sign in and
  start once by hand first (`mix runner.login`, `mix runner.start --root`).

      mix runner.service print       # shows the service file
      mix runner.service install     # writes it and starts the service
      mix runner.service uninstall   # stops the service and removes the file

  The output goes to `runner.log` next to the credentials.
  """
  use Mix.Task

  alias PipeMaestroRunner.CLI
  alias PipeMaestroRunner.Commands.Service

  @impl Mix.Task
  def run(args) do
    CLI.start!()
    CLI.run(&Service.run/1, args)
  end
end
