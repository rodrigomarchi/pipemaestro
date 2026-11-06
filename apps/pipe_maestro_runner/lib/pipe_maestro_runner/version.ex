defmodule PipeMaestroRunner.Version do
  @moduledoc """
  This runner build's version (`PipeMaestroProtocol.Version`), computed
  from the repository when it is compiled and embedded in the build: what
  `pipemaestro --version` prints and the hello announces. It is the version of
  the last commit that changed the runner (`PipeMaestroProtocol.Version.Git.runner/1`),
  so a commit elsewhere in the repository keeps it.

  The module is recompiled whenever the version it would compute changes (a
  commit to the runner's paths, a new tag, another `RUNNER_VERSION`).
  """

  alias PipeMaestroProtocol.Version.Git

  @version Git.runner(__DIR__)

  @doc "This build's version."
  @spec version() :: String.t()
  def version, do: @version

  @doc false
  @spec __mix_recompile__?() :: boolean()
  def __mix_recompile__?, do: Git.runner(__DIR__) != @version
end
