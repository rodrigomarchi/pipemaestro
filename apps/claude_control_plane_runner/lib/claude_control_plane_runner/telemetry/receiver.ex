defmodule ClaudeControlPlaneRunner.Telemetry.Receiver do
  @moduledoc """
  Receives the agent CLI's OpenTelemetry on this machine: a Bandit server on
  127.0.0.1, on a port the system picks, that takes OTLP exports in JSON
  (`POST /v1/logs`, `POST /v1/metrics`, plain or gzip) and sends their
  records (`ClaudeControlPlaneRunner.Telemetry.Otlp`) to the target process
  as `{:telemetry, [{job_id, record}]}`.

  Nothing outside the machine can reach it, and the CLI is pointed at it per
  job (`ClaudeControlPlaneRunner.Claude.env/2`).
  """

  alias ClaudeControlPlaneRunner.Telemetry.Exports

  @doc "Starts listening. Option: `:target` (pid, required)."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    Bandit.start_link(
      plug: {Exports, target: Keyword.fetch!(opts, :target)},
      ip: {127, 0, 0, 1},
      port: 0,
      startup_log: false
    )
  end

  @doc "Where the CLI sends its export: `http://127.0.0.1:<port>`."
  @spec endpoint(pid()) :: String.t()
  def endpoint(server) do
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    "http://127.0.0.1:#{port}"
  end
end
