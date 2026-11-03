defmodule Mix.Tasks.Runner.Login do
  @shortdoc "Signs this runner in to the platform (device flow)"
  @moduledoc """
  Signs this machine in as a runner:

      mix runner.login --url http://localhost:4000 [--name NAME] [--label L]... [--capacity N]

  Shows a URL and a code; a workspace member opens the URL, signed in, and
  approves the runner. The credentials are saved for `mix runner.start`.
  """
  use Mix.Task

  alias ClaudeControlPlaneRunner.CLI
  alias ClaudeControlPlaneRunner.Commands.Login

  @impl Mix.Task
  def run(args) do
    CLI.start!()
    CLI.run(&Login.run/1, args)
  end
end
