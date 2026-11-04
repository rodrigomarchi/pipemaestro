defmodule ClaudeControlPlane.Version do
  @moduledoc """
  This control plane's version (`ClaudeControlPlaneProtocol.Version`), the one
  its pages show and the runners' versions are compared with.

  The build's version is computed from the repository when this module is
  compiled (`CP_VERSION` overrides it, as in the Docker image), and the module
  is recompiled whenever that would change. The application environment can
  pin another one:

      config :claude_control_plane, ClaudeControlPlane.Version, version: "2026-11-04.02"
  """

  alias ClaudeControlPlaneProtocol.Version.Git

  @build_version Git.current(__DIR__)

  @doc "The version this control plane runs as: the configured one, else the build's."
  @spec version() :: String.t()
  def version do
    :claude_control_plane
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
