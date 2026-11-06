defmodule PipeMaestroRunner.LogCollector.Handler do
  @moduledoc false
  # A `:logger` handler that hands every event to the collector, formatted as
  # one line of text. It must never fail: the Logger would remove it.

  alias PipeMaestroRunner.LogCollector

  @spec log(:logger.log_event(), :logger.handler_config()) :: :ok
  def log(%{level: level, msg: msg, meta: meta}, _config) do
    LogCollector.capture(level, message(msg), meta)
  rescue
    _error -> :ok
  end

  defp message({:string, chardata}), do: IO.chardata_to_string(chardata)
  defp message({:report, report}), do: inspect(report)

  defp message({format, args}) when is_list(args),
    do: format |> :io_lib.format(args) |> IO.chardata_to_string()

  defp message(other), do: inspect(other)
end
