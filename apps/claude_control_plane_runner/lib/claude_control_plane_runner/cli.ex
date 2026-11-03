defmodule ClaudeControlPlaneRunner.CLI do
  @moduledoc """
  What the `runner.*` Mix tasks share: they run inside the runner app only, so
  the control plane (database, endpoint) never boots alongside them.
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

  @doc "Loads the saved credentials or stops with the next step to take."
  @spec config!() :: ClaudeControlPlaneRunner.Config.t()
  def config! do
    case ClaudeControlPlaneRunner.Config.load() do
      {:ok, config} ->
        config

      {:error, :not_found} ->
        Mix.raise(
          "Este runner ainda não fez login. Rode: make runner.login URL=<url da plataforma>"
        )

      {:error, :invalid} ->
        Mix.raise(
          "As credenciais em #{ClaudeControlPlaneRunner.Config.path()} estão corrompidas. " <>
            "Rode make runner.logout e depois make runner.login."
        )
    end
  end
end
