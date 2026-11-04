defmodule PipeMaestroRunner.Output do
  @moduledoc """
  Where the runner's commands (`PipeMaestroRunner.Commands`) write: the
  Mix shell when they run as `mix runner.*`, the terminal when they run from
  the release (`pipemaestro`, `PipeMaestroRunner.Main`). A command stops
  with `fail!/1`, which says what to do next.
  """

  alias PipeMaestroRunner.{CommandError, Config}

  @doc "Writes to stdout (the Mix shell under Mix)."
  @spec info(String.t()) :: :ok
  def info(message) do
    if mix?(), do: Mix.shell().info(message), else: IO.puts(message)
    :ok
  end

  @doc "Writes to stderr (the Mix shell under Mix)."
  @spec error(String.t()) :: :ok
  def error(message) do
    if mix?(), do: Mix.shell().error(message), else: IO.puts(:stderr, message)
    :ok
  end

  @doc "Stops the command with `message`."
  @spec fail!(String.t()) :: no_return()
  def fail!(message), do: raise(CommandError, message: message)

  @doc "Loads the saved credentials or stops with the next step to take."
  @spec config!() :: Config.t()
  def config! do
    case Config.load() do
      {:ok, config} ->
        config

      {:error, :not_found} ->
        fail!("Este runner ainda não fez login. Rode: pipemaestro login (ou --url <plataforma>)")

      {:error, :invalid} ->
        fail!(
          "As credenciais em #{Config.path()} estão corrompidas. " <>
            "Rode pipemaestro logout e depois pipemaestro login."
        )
    end
  end

  defp mix?, do: Application.get_env(:pipe_maestro_runner, :output, :mix) == :mix
end
