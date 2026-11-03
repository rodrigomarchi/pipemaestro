defmodule Mix.Tasks.Runner.Doctor do
  @shortdoc "Checks that this machine can work as a runner"
  @moduledoc """
  Checks the agent CLI and how it signs in, git, the saved credentials, the
  root and its directories, the free space for worktrees and whether the
  platform answers (`ClaudeControlPlaneRunner.Doctor`):

      mix runner.doctor

  Exits with an error when a check found a problem.
  """
  use Mix.Task

  alias ClaudeControlPlaneRunner.CLI
  alias ClaudeControlPlaneRunner.Commands.Doctor

  @impl Mix.Task
  def run(args) do
    CLI.start!()
    CLI.run(&Doctor.run/1, args)
  end
end
