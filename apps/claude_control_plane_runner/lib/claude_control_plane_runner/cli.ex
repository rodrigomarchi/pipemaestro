defmodule ClaudeControlPlaneRunner.CLI do
  @moduledoc """
  What the `runner.*` Mix tasks share: they run inside the runner app only, so
  the control plane (database, endpoint) never boots alongside them, and they
  run the same commands as the release (`ClaudeControlPlaneRunner.Commands`).
  """

  @doc "Starts the runner app, refusing to run from the umbrella root."
  @spec start!() :: :ok
  def start! do
    if Mix.Project.umbrella?() do
      Mix.raise("""
      Rode os comandos do runner dentro de apps/claude_control_plane_runner,
      ou pelo Makefile da raiz (make runner.login URL=..., make runner.start).
      Na raiz, o Mix subiria o control plane junto.
      """)
    end

    Mix.Task.run("app.start")
    :ok
  end

  @doc """
  Runs a runner command (`ClaudeControlPlaneRunner.Commands`) as a Mix task:
  a command that stops (`ClaudeControlPlaneRunner.Output.fail!/1`) becomes a
  Mix error.
  """
  @spec run(([String.t()] -> any()), [String.t()]) :: any()
  def run(command, args) do
    command.(args)
  rescue
    error in ClaudeControlPlaneRunner.CommandError -> Mix.raise(error.message)
  end
end
