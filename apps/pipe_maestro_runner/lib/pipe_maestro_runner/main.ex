defmodule PipeMaestroRunner.Main do
  @moduledoc """
  The runner's command line in a release (`pipemaestro <comando>`), the same
  commands `mix runner.*` runs in development (`PipeMaestroRunner.Commands`):

      pipemaestro login --url https://plataforma.exemplo.com
      pipemaestro start [--root ~/src]
      pipemaestro status | logout | doctor
      pipemaestro service print | install | uninstall
      pipemaestro --version
  """

  alias PipeMaestroRunner.{CommandError, Commands}

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
    Application.put_env(:pipe_maestro_runner, :output, :stdio)
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
  The release's entry point (`pipemaestro` runs it with `eval`, which loads the
  code without starting it): starts the runner and runs the command in the
  arguments, then exits with its status.
  """
  @spec main() :: no_return()
  def main do
    {:ok, _apps} = Application.ensure_all_started(:pipe_maestro_runner)
    System.halt(run(System.argv()))
  end
end
