defmodule PipeMaestro.Integrations.IssueUrl do
  @moduledoc """
  The link of an issue on any git host: `https://<host>/<owner>/<repo>/issues/<n>`
  (`http` only on a local host, as `PipeMaestro.Integrations.Connection` takes).
  """

  @doc "The pattern of an issue's link."
  @spec regex() :: Regex.t()
  def regex,
    do: ~r{^(https://[^/\s]+|http://(localhost|127\.0\.0\.1)(:\d+)?)/[\w.-]+/[\w.-]+/issues/\d+$}

  @doc "The message for a link that is not an issue's."
  @spec message() :: String.t()
  def message, do: "use o link de uma issue (https://host/dono/repo/issues/N)"
end
