defmodule PipeMaestroRunner.Commands.Version do
  @moduledoc """
  Prints this runner's version (`PipeMaestroRunner.Version`), and only
  it:

      pipemaestro --version
      pipemaestro version

  With `--next`, prints the next release to cut from this repository on
  today's local date instead (`make runner.release` uses it).
  """

  alias PipeMaestroProtocol.Version.Git
  alias PipeMaestroRunner.{Output, Version}

  @spec run([String.t()]) :: :ok
  def run(["--next"]), do: Output.info(Git.next(File.cwd!(), Git.local_today()))
  def run([]), do: Output.info(Version.version())
  def run(args), do: Output.fail!("Opção inválida: #{Enum.join(args, " ")}")
end
