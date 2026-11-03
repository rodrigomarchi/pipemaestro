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

  alias ClaudeControlPlaneRunner.{CLI, Doctor}

  @impl Mix.Task
  def run(_args) do
    CLI.start!()
    checks = Doctor.run()

    for %{name: name, status: status, detail: detail} <- checks do
      Mix.shell().info("#{mark(status)} #{name}: #{detail}")
    end

    unless Doctor.ok?(checks), do: Mix.raise("Há problemas a resolver antes de rodar tarefas.")
  end

  defp mark(:ok), do: "✓"
  defp mark(:warning), do: "!"
  defp mark(:error), do: "✗"
end
