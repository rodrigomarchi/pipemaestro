defmodule PipeMaestroRunner.Commands.Logout do
  @moduledoc """
  Removes the saved credentials:

      pipemaestro logout

  The runner stays registered on the platform until someone revokes it there.
  """

  alias PipeMaestroRunner.{Config, Output}
  @spec run([String.t()]) :: any()
  def run(_args) do
    :ok = Config.delete()

    Output.info(
      "Credenciais removidas de #{Config.path()}. Para invalidar o token, revogue o runner na plataforma."
    )
  end
end
