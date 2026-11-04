defmodule Mix.Tasks.Runner.Start do
  @shortdoc "Connects this runner to the platform and stays online"
  @moduledoc """
  Connects with the saved credentials and stays online until stopped (Ctrl+C):

      mix runner.start [--root ~/src]

  `--root` is where the code directories it offers are (every directory at its
  first level); it is saved with the credentials, so later starts reuse it.

  Reconnects on its own when the network drops. Stops when the platform
  refuses the runner (revoked), since retrying could not help.

  Runs the jobs the platform sends with the agent CLI (`claude`, or
  `$CLAUDE_BIN`), up to the runner's capacity at once
  (`PipeMaestroRunner.JobRunner`): a task's stages in a git worktree of
  the task's directory (`PipeMaestroRunner.Workspace`), a job on its own
  in the runner's working directory (`workdir` next to the credentials). The
  agent runs with the permission profile of each stage
  (`PipeMaestroRunner.Claude`).
  """
  use Mix.Task

  alias PipeMaestroRunner.CLI
  alias PipeMaestroRunner.Commands.Start

  @impl Mix.Task
  def run(args) do
    CLI.start!()
    CLI.run(&Start.run/1, args)
  end
end
