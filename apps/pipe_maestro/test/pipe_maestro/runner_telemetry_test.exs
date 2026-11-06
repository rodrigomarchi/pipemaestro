defmodule PipeMaestro.RunnerTelemetryTest do
  use PipeMaestro.DataCase, async: true

  import PipeMaestro.Fixtures

  alias PipeMaestro.{Repo, RunnerTelemetry}
  alias PipeMaestro.RunnerTelemetry.Session

  setup do
    workspace = workspace_fixture()
    user = member_fixture(workspace)
    {runner, _token} = runner_fixture(workspace, user)
    runner = backdate(runner, ~U[2026-11-01 00:00:00Z])
    %{runner: runner}
  end

  defp backdate(runner, at) do
    runner |> Ecto.Changeset.change(inserted_at: at) |> Repo.update!()
  end

  defp at(time), do: DateTime.new!(~D[2026-11-10], time) |> DateTime.add(0, :microsecond)

  describe "sessions" do
    test "a join opens one; its end closes it with the reason", %{runner: runner} do
      session = RunnerTelemetry.open_session(runner, at(~T[10:00:00]))
      assert :ok = RunnerTelemetry.close_session(session.id, "closed", at(~T[11:00:00]))

      assert [%Session{end_reason: "closed", ended_at: ended}] =
               RunnerTelemetry.sessions(runner, at(~T[00:00:00]))

      assert ended == at(~T[11:00:00])

      # Closing again changes nothing.
      RunnerTelemetry.close_session(session.id, "crashed", at(~T[12:00:00]))
      assert [%Session{end_reason: "closed"}] = RunnerTelemetry.sessions(runner, at(~T[00:00:00]))
    end

    test "a new join closes the one still open as reconnected", %{runner: runner} do
      first = RunnerTelemetry.open_session(runner, at(~T[10:00:00]))
      second = RunnerTelemetry.open_session(runner, at(~T[10:05:00]))

      assert [%Session{id: id2, ended_at: nil}, %Session{id: id1, end_reason: "reconnected"}] =
               RunnerTelemetry.sessions(runner, at(~T[00:00:00]))

      assert {id1, id2} == {first.id, second.id}
    end

    test "a refused join is a session that ends as it starts", %{runner: runner} do
      refusal =
        RunnerTelemetry.record_refusal(runner, "outdated", "2026-01-01.01", at(~T[09:00:00]))

      assert refusal.started_at == refusal.ended_at
      assert Session.refused?(refusal)
      assert refusal.runner_version == "2026-01-01.01"
    end

    test "the sessions a restart left open close as restart", %{runner: runner} do
      RunnerTelemetry.open_session(runner, at(~T[08:00:00]))
      assert RunnerTelemetry.close_orphan_sessions(at(~T[09:00:00])) == 1

      assert [%Session{end_reason: "restart"}] =
               RunnerTelemetry.sessions(runner, at(~T[00:00:00]))

      assert RunnerTelemetry.close_orphan_sessions(at(~T[09:00:00])) == 0
    end
  end

  describe "uptime and drops" do
    test "the connected share of the period, overlaps counted once", %{runner: runner} do
      since = at(~T[00:00:00])
      now = at(~T[10:00:00])

      s1 = RunnerTelemetry.open_session(runner, at(~T[01:00:00]))
      RunnerTelemetry.close_session(s1.id, "closed", at(~T[03:00:00]))
      s2 = RunnerTelemetry.open_session(runner, at(~T[05:00:00]))
      RunnerTelemetry.close_session(s2.id, "crashed", at(~T[06:00:00]))
      # Still open: counts up to now.
      RunnerTelemetry.open_session(runner, at(~T[08:00:00]))

      assert_in_delta RunnerTelemetry.uptime(runner, since, now), 5 / 10, 0.0001
      assert RunnerTelemetry.drops(runner, since, now) == 2
    end

    test "a runner's period starts when it was created", %{runner: runner} do
      runner = backdate(runner, ~U[2026-11-10 08:00:00Z])
      RunnerTelemetry.open_session(runner, at(~T[09:00:00]))

      assert_in_delta RunnerTelemetry.uptime(runner, at(~T[00:00:00]), at(~T[10:00:00])),
                      0.5,
                      0.0001

      assert RunnerTelemetry.uptime(runner, at(~T[00:00:00]), ~U[2026-11-10 08:00:00Z]) == nil
    end

    test "revocations and refusals are not drops", %{runner: runner} do
      s = RunnerTelemetry.open_session(runner, at(~T[01:00:00]))
      RunnerTelemetry.close_session(s.id, "revoked", at(~T[02:00:00]))
      RunnerTelemetry.record_refusal(runner, "outdated", nil, at(~T[03:00:00]))
      assert RunnerTelemetry.drops(runner, at(~T[00:00:00]), at(~T[10:00:00])) == 0
    end

    test "for several runners at once", %{runner: runner} do
      assert %{} = uptimes = RunnerTelemetry.uptimes([runner], at(~T[00:00:00]), at(~T[10:00:00]))
      assert uptimes[runner.id] == 0.0
    end
  end
end
