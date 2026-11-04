defmodule PipeMaestroRunner.Telemetry.Otlp do
  @moduledoc """
  Reads an OTLP export in JSON (`http/json`: `resourceLogs` from `/v1/logs`,
  `resourceMetrics` from `/v1/metrics`) from the agent CLI into the records
  of `PipeMaestroProtocol.Telemetry`, each with the job it belongs to:
  the runner starts each CLI with the resource attribute `cp.job_id`.

  Log records are the CLI's events (`claude_code.api_request` →
  `"api_request"`); metric data points are increments over the export
  interval (the CLI's default delta temporality), named `"metric:<name>"`
  with their value in `"value"`. What the protocol does not keep is dropped.
  """

  alias PipeMaestroProtocol.Telemetry

  @job_attribute "cp.job_id"

  @doc "The resource attribute that names the job."
  @spec job_attribute() :: String.t()
  def job_attribute, do: @job_attribute

  @doc "The records in an export, as `{job_id, record}`."
  @spec records(map()) :: [{String.t(), map()}]
  def records(%{"resourceLogs" => resources}) when is_list(resources) do
    for %{} = resource <- resources,
        job_id = job_id(resource),
        job_id != nil,
        %{"logRecords" => records} <- List.wrap(resource["scopeLogs"]),
        %{} = record <- List.wrap(records),
        kept = log_record(record),
        kept != nil,
        do: {job_id, kept}
  end

  def records(%{"resourceMetrics" => resources}) when is_list(resources) do
    for %{} = resource <- resources,
        job_id = job_id(resource),
        job_id != nil,
        %{"metrics" => metrics} <- List.wrap(resource["scopeMetrics"]),
        %{"name" => name} = metric <- List.wrap(metrics),
        point <- data_points(metric),
        kept = metric_point(name, point),
        kept != nil,
        do: {job_id, kept}
  end

  def records(_export), do: []

  defp job_id(resource),
    do: attributes(get_in(resource, ["resource", "attributes"]))[@job_attribute]

  defp log_record(record) do
    attrs = attributes(record["attributes"])
    name = event_name(record["body"], attrs)
    Telemetry.record(name, attrs["event.timestamp"] || nano_iso(record["timeUnixNano"]), attrs)
  end

  defp event_name(%{"stringValue" => "claude_code." <> name}, _attrs), do: name
  defp event_name(_body, %{"event.name" => name}) when is_binary(name), do: name
  defp event_name(_body, _attrs), do: nil

  defp data_points(metric) do
    Enum.find_value(~w(sum gauge histogram), [], fn kind ->
      case metric[kind] do
        %{"dataPoints" => points} when is_list(points) -> points
        _other -> nil
      end
    end)
  end

  defp metric_point("claude_code." <> name, point) do
    value = point["asDouble"] || point["asInt"]

    Telemetry.record(
      ("metric:" <> String.replace_suffix(name, ".count", ""))
      |> String.replace_suffix(".total", ""),
      nano_iso(point["timeUnixNano"]),
      Map.put(attributes(point["attributes"]), "value", value)
    )
  end

  defp metric_point(_name, _point), do: nil

  # OTLP attributes are `[%{"key", "value" => %{"<type>Value" => v}}]`.
  defp attributes(list) when is_list(list) do
    for %{"key" => key, "value" => %{} = value} <- list, into: %{} do
      {key, value |> Map.values() |> List.first()}
    end
  end

  defp attributes(_list), do: %{}

  defp nano_iso(nanos) do
    with nanos when nanos != nil <- nanos,
         {integer, _rest} <- Integer.parse(to_string(nanos)),
         {:ok, at} <- DateTime.from_unix(integer, :nanosecond) do
      at |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
    else
      _unknown -> DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
    end
  end
end
