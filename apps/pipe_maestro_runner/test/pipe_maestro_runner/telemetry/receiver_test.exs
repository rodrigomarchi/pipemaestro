defmodule PipeMaestroRunner.Telemetry.ReceiverTest do
  use ExUnit.Case, async: true

  alias PipeMaestroRunner.Telemetry.Receiver

  @fixtures Path.expand("../../fixtures/claude_run", __DIR__)

  setup do
    {:ok, receiver} = Receiver.start_link(target: self())
    %{endpoint: Receiver.endpoint(receiver)}
  end

  test "listens on this machine only and relays what an export carries", %{endpoint: endpoint} do
    assert "http://127.0.0.1:" <> _port = endpoint

    body = File.read!(Path.join(@fixtures, "otlp_logs.json"))

    response =
      Req.post!(endpoint <> "/v1/logs",
        body: body,
        headers: [{"content-type", "application/json"}],
        retry: false
      )

    assert response.status == 200
    assert_receive {:telemetry, records}
    assert Enum.any?(records, &match?({"captura-1", %{"name" => "api_request"}}, &1))
  end

  test "takes a compressed export and answers anything else without relaying", %{
    endpoint: endpoint
  } do
    body = :zlib.gzip(File.read!(Path.join(@fixtures, "otlp_metrics.json")))

    assert Req.post!(endpoint <> "/v1/metrics",
             body: body,
             headers: [{"content-type", "application/json"}, {"content-encoding", "gzip"}],
             retry: false
           ).status == 200

    assert_receive {:telemetry, [_ | _]}

    assert Req.post!(endpoint <> "/v1/logs", body: "não é json", retry: false).status == 400

    assert Req.post!(endpoint <> "/v1/logs",
             body: "não é gzip",
             headers: [{"content-encoding", "gzip"}],
             retry: false
           ).status == 400

    assert Req.get!(endpoint <> "/", retry: false).status == 404
    refute_receive {:telemetry, _}
  end
end
