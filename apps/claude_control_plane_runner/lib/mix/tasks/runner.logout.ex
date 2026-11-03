defmodule Mix.Tasks.Runner.Logout do
  @shortdoc "Removes this runner's saved credentials"
  @moduledoc """
  Removes the saved credentials:

      mix runner.logout

  The runner stays registered on the platform until someone revokes it there.
  """
  use Mix.Task

  alias ClaudeControlPlaneRunner.CLI
  alias ClaudeControlPlaneRunner.Commands.Logout

  @impl Mix.Task
  def run(args) do
    CLI.run(&Logout.run/1, args)
  end
end
