defmodule PipeMaestroRunner.ConnectionDoctorTest do
  use Slipstream.SocketTest

  alias PipeMaestroProtocol.RunnerDoctor
  alias PipeMaestroRunner.{Connection, Host}

  @config %{
    url: "http://localhost:4000",
    runner_id: "r1",
    runner_name: "build-01",
    token: "cpr_token",
    workspace_name: "Acme",
    workspace_slug: "acme",
    labels: [],
    capacity: nil
  }

  @moduletag :tmp_dir

  @fake Path.expand("../support/fake_claude", __DIR__)

  test "diagnoses after joining and when the platform asks", %{tmp_dir: dir} do
    {:ok, hello} = Host.hello()

    client =
      start_supervised!(
        {Connection,
         config: @config,
         hello: hello,
         workdir: dir,
         doctor_every: 60_000,
         doctor_opts: [gh: nil, executable: {:ok, @fake}, api_key: nil],
         connect_options: [test_mode?: true]}
      )

    connect_and_assert_join(client, "runner:r1", _params, :ok)
    assert_push("runner:r1", "worktree:usage", _usage, _ref, 5_000)
    assert_push("runner:r1", "runner:doctor", diagnosis, _ref, 10_000)
    assert {:ok, %{"request_id" => nil, "checks" => checks}} = RunnerDoctor.parse(diagnosis)

    by_key = Map.new(checks, &{&1["key"], &1})
    assert by_key["platform"]["status"] == "ok"
    assert by_key["gh"]["status"] == "warning"
    assert by_key["config"]["detail"] =~ "build-01"

    push(client, "runner:r1", "runner:doctor", %{"request_id" => "req-7"})
    assert_push("runner:r1", "runner:doctor", %{"request_id" => "req-7"}, _ref, 10_000)
  end
end
