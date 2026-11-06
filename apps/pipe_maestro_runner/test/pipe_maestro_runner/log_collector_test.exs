defmodule PipeMaestroRunner.LogCollectorTest do
  # The collector has a name, and the Logger handler is global.
  use ExUnit.Case, async: false

  require Logger

  alias PipeMaestroProtocol.RunnerLog
  alias PipeMaestroRunner.LogCollector

  defp start(opts \\ []) do
    start_supervised!({LogCollector, Keyword.merge([flush_every: 60_000], opts)})
  end

  defp lines do
    LogCollector.flush()
    assert_receive {:runner_log, lines}
    lines
  end

  test "keeps what comes before a sink and hands it over when one attaches" do
    start(keep: 2)
    for n <- 1..3, do: LogCollector.capture(:info, "linha #{n}")
    LogCollector.attach(self())

    assert_receive {:runner_log, lines}
    assert Enum.map(lines, & &1["message"]) == ["linha 2", "linha 3"]
    assert {:ok, _parsed} = RunnerLog.parse(%{"lines" => lines})
  end

  test "redacts the secrets it knows, and stops when told" do
    start(secrets: ["cpr_token_do_runner", "abc"])
    LogCollector.attach(self())
    LogCollector.add_secrets("j1", ["senha-do-job", "senha-do-job-longa"])

    LogCollector.capture(
      :info,
      "token cpr_token_do_runner, senha-do-job-longa e senha-do-job; abc"
    )

    assert [%{"message" => message}] = lines()
    assert message == "token [redigido], [redigido] e [redigido]; abc"

    LogCollector.forget_secrets("j1")
    LogCollector.capture(:info, "senha-do-job")
    assert [%{"message" => "senha-do-job"}] = lines()
  end

  test "sends full batches at once" do
    start()
    LogCollector.attach(self())
    for n <- 1..RunnerLog.max_lines(), do: LogCollector.capture(:info, "#{n}")
    assert_receive {:runner_log, lines}, 1_000
    assert length(lines) == RunnerLog.max_lines()
  end

  test "past the ceiling a minute, the lines are counted and told" do
    start(per_minute: 2)
    LogCollector.attach(self())
    for n <- 1..5, do: LogCollector.capture(:info, "#{n}")
    assert length(lines()) == 2

    # The next minute tells how many went.
    send(
      Process.whereis(LogCollector),
      {:"$gen_cast", {:capture, DateTime.add(DateTime.utc_now(), 61), "info", "depois", %{}}}
    )

    assert [%{"event" => "log_dropped", "attrs" => %{"count" => 3}}, %{"message" => "depois"}] =
             lines()
  end

  test "with the log not kept, only the events go" do
    start()
    LogCollector.attach(self(), false)
    LogCollector.capture(:info, "comum")

    LogCollector.capture(:warning, "atualizou", %{
      runner_event: "update_applied",
      event_attrs: %{"version" => "v2"}
    })

    assert [%{"event" => "update_applied", "level" => "warning", "attrs" => %{"version" => "v2"}}] =
             lines()
  end

  test "the Logger's events reach it, with their event" do
    start()
    LogCollector.attach(self())
    :ok = LogCollector.install_handler()
    on_exit(fn -> LogCollector.remove_handler() end)

    ExUnit.CaptureLog.capture_log(fn ->
      Logger.warning("o scratch não saiu",
        runner_event: "scratch_remove_failed",
        event_attrs: %{"job_id" => "j1"}
      )

      Logger.error("falhou ~p", [])
    end)

    assert [%{"message" => "o scratch não saiu", "event" => "scratch_remove_failed"} | _rest] =
             lines()
  end

  test "without the collector, nothing happens" do
    assert LogCollector.capture(:info, "x") == :ok
    assert LogCollector.flush() == :ok
    assert LogCollector.add_secrets("j", ["segredo"]) == :ok
  end
end
