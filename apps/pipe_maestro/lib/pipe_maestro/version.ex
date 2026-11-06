defmodule PipeMaestro.Version do
  @moduledoc """
  This control plane's version (`PipeMaestroProtocol.Version`), the one its
  pages show, and the runner's version it requires of the runners that
  connect.

  Both are computed from the repository when this module is compiled: the
  control plane's from `HEAD` (`CP_VERSION` overrides it, as in the Docker
  image), the runner's from the last commit that changed the runner
  (`RUNNER_VERSION` overrides it). The module is recompiled whenever either
  would change. The application environment can pin others:

      config :pipe_maestro, PipeMaestro.Version,
        version: "2026-11-04.02",
        runner_version: "2026-11-03.02"
  """

  alias PipeMaestroProtocol.Version.Git

  @build_version Git.current(__DIR__)
  @build_runner_version Git.runner(__DIR__)

  @doc "The version this control plane runs as: the configured one, else the build's."
  @spec version() :: String.t()
  def version, do: configured(:version) || build_version()

  @doc """
  The runner's version this control plane requires: the configured one, else
  the build's.
  """
  @spec runner_version() :: String.t()
  def runner_version, do: configured(:runner_version) || build_runner_version()

  @doc "The control plane's version computed when this build was compiled."
  @spec build_version() :: String.t()
  def build_version, do: @build_version

  @doc "The runner's version computed when this build was compiled."
  @spec build_runner_version() :: String.t()
  def build_runner_version, do: @build_runner_version

  @doc false
  @spec __mix_recompile__?() :: boolean()
  def __mix_recompile__? do
    Git.current(__DIR__) != @build_version or Git.runner(__DIR__) != @build_runner_version
  end

  defp configured(key) do
    :pipe_maestro
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key)
  end
end
