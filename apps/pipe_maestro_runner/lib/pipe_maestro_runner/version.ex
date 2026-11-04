defmodule PipeMaestroRunner.Version do
  @moduledoc """
  This runner build's version (`PipeMaestroProtocol.Version`), computed
  from the repository when it is compiled and embedded in the build: what
  `pipemaestro --version` prints and the hello announces.

  The module is recompiled whenever the version it would compute changes (a
  new commit, a new tag, another `CP_VERSION`).
  """

  alias PipeMaestroProtocol.Version.Git

  @version Git.current(__DIR__)

  @doc "This build's version."
  @spec version() :: String.t()
  def version, do: @version

  @doc false
  @spec __mix_recompile__?() :: boolean()
  def __mix_recompile__?, do: Git.current(__DIR__) != @version
end
