defmodule Mix.Tasks.Runner.Status do
  @shortdoc "Shows this runner's credentials and whether the platform accepts them"
  @moduledoc """
  Shows the saved credentials and tries a connection to check them:

      mix runner.status
  """
  use Mix.Task

  alias PipeMaestroRunner.CLI
  alias PipeMaestroRunner.Commands.Status

  @impl Mix.Task
  def run(args) do
    CLI.start!()
    CLI.run(&Status.run/1, args)
  end
end
