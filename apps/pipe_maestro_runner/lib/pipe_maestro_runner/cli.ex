defmodule PipeMaestroRunner.CLI do
  @moduledoc """
  What the `runner.*` Mix tasks share: they run inside the runner app only, so
  the control plane (database, endpoint) never boots alongside them, and they
  run the same commands as the release (`PipeMaestroRunner.Commands`).
  """

  @doc "Starts the runner app, refusing to run from the umbrella root."
  @spec start!() :: :ok
  def start! do
    outside_umbrella!()
    Mix.Task.run("app.start")
    :ok
  end

  @doc """
  Compiles the runner without starting it, for a command that only reads what
  was compiled (its version): starting would load config/runtime.exs, which in
  prod asks for the control plane's settings.
  """
  @spec compile!() :: :ok
  def compile! do
    outside_umbrella!()
    Mix.Task.run("compile")
    :ok
  end

  defp outside_umbrella! do
    if Mix.Project.umbrella?() do
      Mix.raise("""
      Rode os comandos do runner dentro de apps/pipe_maestro_runner,
      ou pelo Makefile da raiz (make runner.login URL=..., make runner.start).
      Na raiz, o Mix subiria o control plane junto.
      """)
    end
  end

  @doc """
  Runs a runner command (`PipeMaestroRunner.Commands`) as a Mix task:
  a command that stops (`PipeMaestroRunner.Output.fail!/1`) becomes a
  Mix error.
  """
  @spec run(([String.t()] -> any()), [String.t()]) :: any()
  def run(command, args) do
    command.(args)
  rescue
    error in PipeMaestroRunner.CommandError -> Mix.raise(error.message)
  end
end
