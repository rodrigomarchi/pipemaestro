defmodule PipeMaestroRunner.Telemetry.Exports do
  @moduledoc """
  The plug behind `PipeMaestroRunner.Telemetry.Receiver`: takes an
  OTLP export in JSON at `/v1/logs` or `/v1/metrics` and sends its records to
  the target; anything else is refused (400 for a body that is not an
  export, 404 for another path).
  """
  @behaviour Plug

  import Plug.Conn

  alias PipeMaestroRunner.Telemetry.Otlp

  @max_body 10_000_000

  @impl true
  def init(opts), do: Keyword.fetch!(opts, :target)

  @impl true
  def call(%Plug.Conn{method: "POST", path_info: ["v1", signal]} = conn, target)
      when signal in ["logs", "metrics"] do
    with {:ok, body, conn} <- read_body(conn, length: @max_body),
         {:ok, %{} = export} <-
           body |> decode(get_req_header(conn, "content-encoding")) |> JSON.decode() do
      send(target, {:telemetry, Otlp.records(export)})
      conn |> put_resp_content_type("application/json") |> send_resp(200, "{}")
    else
      _too_large_or_not_an_export -> send_resp(conn, 400, "")
    end
  end

  def call(conn, _target), do: send_resp(conn, 404, "")

  # A broken gzip body reads as empty, which is not JSON: a 400.
  defp decode(body, ["gzip"]) do
    :zlib.gunzip(body)
  rescue
    ErlangError -> ""
  end

  defp decode(body, _identity), do: body
end
