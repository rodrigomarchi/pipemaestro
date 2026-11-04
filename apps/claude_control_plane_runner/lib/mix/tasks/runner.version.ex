defmodule Mix.Tasks.Runner.Version do
  @shortdoc "Prints this runner's version, or the next release to cut"
  @moduledoc """
  Prints this runner's version (`ClaudeControlPlaneRunner.Commands.Version`):

      mix runner.version
      mix runner.version --next
  """
  use Mix.Task

  alias ClaudeControlPlaneRunner.CLI
  alias ClaudeControlPlaneRunner.Commands.Version

  @impl Mix.Task
  def run(args) do
    CLI.start!()
    CLI.run(&Version.run/1, args)
  end
end
