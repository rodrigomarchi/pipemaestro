defmodule ClaudeControlPlaneRunner.OutboxTest do
  use ExUnit.Case, async: true

  alias ClaudeControlPlaneRunner.Outbox

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
end
