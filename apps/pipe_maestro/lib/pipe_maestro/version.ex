defmodule PipeMaestro.Version do
  @moduledoc """
  This control plane's version (`PipeMaestroProtocol.Version`), the one
  its pages show and the runners' versions are compared with.

  The build's version is computed from the repository when this module is
  compiled (`CP_VERSION` overrides it, as in the Docker image), and the module
  is recompiled whenever that would change. The application environment can
  pin another one:

      config :pipe_maestro, PipeMaestro.Version, version: "2026-11-04.02"
  """

  alias PipeMaestroProtocol.Version.Git

  @build_version Git.current(__DIR__)

  @doc "The version this control plane runs as: the configured one, else the build's."
  @spec version() :: String.t()
  def version do
    :pipe_maestro
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:version)
    |> Kernel.||(build_version())
  end

  @doc "The version computed when this build was compiled."
  @spec build_version() :: String.t()
  def build_version, do: @build_version

  @doc false
  @spec __mix_recompile__?() :: boolean()
  def __mix_recompile__?, do: Git.current(__DIR__) != @build_version
end
