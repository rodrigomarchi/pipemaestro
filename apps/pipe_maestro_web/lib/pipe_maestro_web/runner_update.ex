defmodule PipeMaestroWeb.RunnerUpdate do
  @moduledoc """
  What a runner not on this control plane's version is told when it is
  refused (`PipeMaestro.Runners.version_check/1`), on login and on every
  (re)join: the version it must run and where to download it.

  `download_url` is a directory with one binary per target and a
  `SHA256SUMS` (`PipeMaestroProtocol.Downloads`); a runner updates itself
  from it only when it is on the platform's own origin.
  """

  alias PipeMaestroWeb.RunnerComponents

  @doc """
  The refusal for a runner announcing `runner_version` when `expected` is
  this control plane's: `%{"reason" => "outdated", "version", "runner_version",
  "download_url"}`.
  """
  @spec refusal(String.t() | nil, String.t()) :: %{String.t() => String.t() | nil}
  def refusal(runner_version, expected) do
    %{
      "reason" => "outdated",
      "version" => expected,
      "runner_version" => runner_version,
      "download_url" => download_url()
    }
  end

  @doc """
  Where the runner's binaries are (the deploy publishes them,
  `:runner_downloads_url`), as a full URL; without them, the platform's.
  """
  @spec download_url() :: String.t()
  def download_url do
    base = PipeMaestroWeb.Endpoint.url()

    case RunnerComponents.downloads_url() do
      nil -> base
      "/" <> _path = path -> base <> path <> "/"
      url -> url
    end
  end
end
