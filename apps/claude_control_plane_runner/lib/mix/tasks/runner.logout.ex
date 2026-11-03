defmodule Mix.Tasks.Runner.Logout do
  @shortdoc "Removes this runner's saved credentials"
  @moduledoc """
  Removes the saved credentials:

      mix runner.logout

  The runner stays registered on the platform until someone revokes it there.
  """
  use Mix.Task

  alias ClaudeControlPlaneRunner.Config

  @impl Mix.Task
  def run(_args) do
    :ok = Config.delete()

    Mix.shell().info(
      "Credenciais removidas de #{Config.path()}. Para invalidar o token, revogue o runner na plataforma."
    )
  end
end
