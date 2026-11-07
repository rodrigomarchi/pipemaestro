defmodule PipeMaestroRunner.OutboxTest do
  use ExUnit.Case, async: true

  alias PipeMaestroRunner.Outbox

  defp add_all(outbox, messages) do
    Enum.reduce(messages, outbox, fn {event, payload}, outbox ->
      {_id, outbox} = Outbox.add(outbox, event, payload)
      outbox
    end)
  end

  test "keeps messages in order until each is confirmed" do
    outbox =
      add_all(Outbox.new(), [
        {"job:started", %{"job_id" => "j1"}},
        {"job:event", %{"job_id" => "j1", "seq" => 1}},
        {"job:started", %{"job_id" => "j2"}}
      ])

    assert [{id1, "job:started", _}, {id2, "job:event", _}, {id3, _, _}] = Outbox.pending(outbox)
    assert Outbox.job_ids(outbox) == ["j1", "j2"]

    outbox = outbox |> Outbox.sent(id1, :r1) |> Outbox.sent(id2, :r2) |> Outbox.sent(id3, :r3)
    outbox = outbox |> Outbox.confirmed(:r1) |> Outbox.confirmed(:r3)
    assert [{^id2, "job:event", _}] = Outbox.pending(outbox)
    assert Outbox.job_ids(outbox) == ["j1"]

    # A confirmation that arrives for a ref of a previous connection is ignored.
    outbox = Outbox.forget_refs(outbox)
    assert Outbox.confirmed(outbox, :r2) == outbox
  end

  test "when full, drops the oldest events but never a start or an end" do
    outbox =
      add_all(Outbox.new(3), [
        {"job:started", %{"job_id" => "j1"}},
        {"job:event", %{"job_id" => "j1", "seq" => 1}},
        {"job:event", %{"job_id" => "j1", "seq" => 2}},
        {"job:finished", %{"job_id" => "j1"}}
      ])

    assert Enum.map(Outbox.pending(outbox), fn {_id, event, p} -> {event, p["seq"]} end) == [
             {"job:started", nil},
             {"job:event", 2},
             {"job:finished", nil}
           ]
  end

  test "telemetry goes like the events when the outbox is full" do
    outbox =
      add_all(Outbox.new(2), [
        {"job:telemetry", %{"job_id" => "j1", "records" => []}},
        {"job:started", %{"job_id" => "j2"}},
        {"job:finished", %{"job_id" => "j2"}}
      ])

    assert Enum.map(Outbox.pending(outbox), fn {_id, event, _p} -> event end) ==
             ["job:started", "job:finished"]
  end

  @tag :tmp_dir
  test "a job's end survives a restart; its events do not", %{tmp_dir: dir} do
    path = Path.join(dir, "outbox.bin")

    outbox =
      add_all(Outbox.new(20_000, path), [
        {"job:event", %{"job_id" => "j1", "seq" => 1}},
        {"job:finished", %{"job_id" => "j1", "status" => "succeeded"}},
        {"worktree:removed", %{"task_id" => "t1"}}
      ])

    # Another process (the runner after a restart) finds what was not confirmed.
    restarted = Outbox.new(20_000, path)

    assert Enum.map(Outbox.pending(restarted), fn {_id, event, _p} -> event end) ==
             ["job:finished", "worktree:removed"]

    assert Outbox.job_ids(restarted) == ["j1"]

    # Once confirmed, it is gone from disk too.
    [{id, _, _} | _] = Outbox.pending(outbox)
    outbox |> Outbox.sent(id + 1, :r) |> Outbox.confirmed(:r)

    assert Enum.map(Outbox.pending(Outbox.new(20_000, path)), fn {_, e, _} -> e end) == [
             "worktree:removed"
           ]

    # A corrupt file is no reason not to start.
    File.write!(path, "lixo")
    assert Outbox.pending(Outbox.new(20_000, path)) == []
  end

  @tag :tmp_dir
  test "before an update, everything still to confirm goes to the file, in order",
       %{tmp_dir: dir} do
    path = Path.join(dir, "outbox.bin")

    outbox =
      add_all(Outbox.new(20_000, path), [
        {"job:started", %{"job_id" => "j1"}},
        {"job:event", %{"job_id" => "j1", "seq" => 1}},
        {"job:telemetry", %{"job_id" => "j1", "records" => []}},
        {"job:finished", %{"job_id" => "j1", "status" => "succeeded"}}
      ])

    assert Outbox.persist_all(outbox) == :ok

    restarted = Outbox.new(20_000, path)

    assert Enum.map(Outbox.pending(restarted), fn {_id, event, _p} -> event end) ==
             ["job:started", "job:event", "job:telemetry", "job:finished"]

    assert Outbox.job_ids(restarted) == ["j1"]
  end

  test "persist_all/1 without a file has nothing to do" do
    outbox = add_all(Outbox.new(), [{"job:event", %{"job_id" => "j1", "seq" => 1}}])
    assert Outbox.persist_all(outbox) == :ok
  end
end
