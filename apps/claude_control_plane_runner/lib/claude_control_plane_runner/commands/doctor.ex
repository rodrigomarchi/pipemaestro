defmodule ClaudeControlPlaneRunner.Commands.Doctor do
  @moduledoc """
  Checks the agent CLI and how it signs in, git, the saved credentials, the
  root and its directories, the free space for worktrees and whether the
  platform answers (`ClaudeControlPlaneRunner.Doctor`):

      cp-runner doctor

  Exits with an error when a check found a problem.
  """

  alias ClaudeControlPlaneRunner.{Doctor, Output}
  @spec run([String.t()]) :: any()
  def run(_args) do
    checks = Doctor.run()

    for %{name: name, status: status, detail: detail} <- checks do
      Output.info("#{mark(status)} #{name}: #{detail}")
    end

    unless Doctor.ok?(checks), do: Output.fail!("Há problemas a resolver antes de rodar tarefas.")
  end

  defp mark(:ok), do: "✓"
  defp mark(:warning), do: "!"
  defp mark(:error), do: "✗"
end
