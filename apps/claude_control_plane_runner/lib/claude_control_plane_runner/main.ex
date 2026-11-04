defmodule ClaudeControlPlaneRunner.Main do
  @moduledoc """
  The runner's command line in a release (`cp-runner <comando>`), the same
  commands `mix runner.*` runs in development (`ClaudeControlPlaneRunner.Commands`):

      cp-runner login --url https://plataforma.exemplo.com
      cp-runner start [--root ~/src]
      cp-runner status | logout | doctor
      cp-runner service print | install | uninstall
      cp-runner --version
  """

  alias ClaudeControlPlaneRunner.{CommandError, Commands}

  @commands %{
    "login" => Commands.Login,
    "start" => Commands.Start,
    "status" => Commands.Status,
    "logout" => Commands.Logout,
    "doctor" => Commands.Doctor,
    "service" => Commands.Service,
    "version" => Commands.Version,
    "--version" => Commands.Version
  }

  @doc "Runs a command; returns the exit status."
  @spec run([String.t()]) :: non_neg_integer()
  def run([command | args]) when is_map_key(@commands, command) do
    Application.put_env(:claude_control_plane_runner, :output, :stdio)
    @commands[command].run(args)
    0
  rescue
    error in CommandError ->
      IO.puts(:stderr, error.message)
      1
  end

  def run(_args) do
    IO.puts(:stderr, @moduledoc |> String.split("\n\n") |> Enum.at(1) |> String.trim())
    2
  end

  @doc """
  The release's entry point (`cp-runner` runs it with `eval`, which loads the
  code without starting it): starts the runner and runs the command in the
  arguments, then exits with its status.
  """
  @spec main() :: no_return()
  def main do
    {:ok, _apps} = Application.ensure_all_started(:claude_control_plane_runner)
    System.halt(run(System.argv()))
  end
end
