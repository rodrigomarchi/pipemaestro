defmodule PipeMaestro.RunnerTelemetryTest do
  use PipeMaestro.DataCase, async: true

  import PipeMaestro.Fixtures

  alias PipeMaestro.Jobs.Job
  alias PipeMaestro.Repo
  alias PipeMaestro.RunnerTelemetry
  alias PipeMaestro.RunnerTelemetry.{HealthSample, Session}

  setup do
    workspace = workspace_fixture()
    user = member_fixture(workspace)
    {runner, _token} = runner_fixture(workspace, user)
    runner = backdate(runner, ~U[2026-11-01 00:00:00Z])
    %{runner: runner, user: user}
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

  describe "health" do
    defp sample(at, attrs \\ %{}) do
      Map.merge(
        %{
          "at" => DateTime.to_iso8601(at),
          "cpu_pct" => 10,
          "load1" => 1.5,
          "mem_used_bytes" => 4_000,
          "mem_total_bytes" => 16_000,
          "disk_free_bytes" => 50_000,
          "disk_total_bytes" => 100_000,
          "outbox_pending" => 0,
          "running_jobs" => 1,
          "beam_bytes" => 90_000_000
        },
        attrs
      )
    end

    test "stores a sample; one from the future is dated now", %{runner: runner} do
      now = ~U[2026-11-10 10:00:00.000000Z]

      assert {:ok, %HealthSample{cpu_pct: 10.0, load1: 1.5}} =
               RunnerTelemetry.record_health(runner, sample(at(~T[09:59:00])), now)

      assert {:ok, %HealthSample{at: ^now}} =
               RunnerTelemetry.record_health(runner, sample(at(~T[11:00:00])), now)

      assert {:error, _} = RunnerTelemetry.record_health(runner, %{"cpu_pct" => 1}, now)

      latest = RunnerTelemetry.latest_health(runner)
      assert latest.at == now
      assert HealthSample.mem_share(latest) == 0.25
      assert HealthSample.disk_free_share(latest) == 0.5
      assert length(RunnerTelemetry.recent_health(runner, 5)) == 2
    end

    test "a series averages each bucket and skips the empty ones", %{runner: runner} do
      now = ~U[2026-11-10 12:00:00.000000Z]

      for {time, cpu, free} <- [
            {~T[10:01:00], 10, 60_000},
            {~T[10:02:00], 30, 40_000},
            {~T[11:30:00], 50, 30_000}
          ] do
        {:ok, _} =
          RunnerTelemetry.record_health(
            runner,
            sample(at(time), %{"cpu_pct" => cpu, "disk_free_bytes" => free}),
            now
          )
      end

      assert [first, second] = RunnerTelemetry.health_series(runner, at(~T[10:00:00]), 3_600)
      assert first.cpu_pct == 20.0
      assert first.disk_free_bytes == 40_000
      assert first.mem_pct == 25.0
      assert second.cpu_pct == 50.0
    end

    test "nothing measured yet", %{runner: runner} do
      assert RunnerTelemetry.latest_health(runner) == nil
      assert RunnerTelemetry.health_series(runner, at(~T[00:00:00]), 60) == []
      assert HealthSample.mem_share(%HealthSample{}) == nil
      assert HealthSample.disk_free_share(%HealthSample{}) == nil
    end
  end

  describe "run stats" do
    defp finished(runner, user, status, attrs) do
      job = job_fixture(runner, user)

      job
      |> Ecto.Changeset.change(
        Keyword.merge(
          [
            status: status,
            started_at: DateTime.add(job.inserted_at, 2, :second),
            finished_at: DateTime.utc_now(:second)
          ],
          attrs
        )
      )
      |> Repo.update!()
    end

    test "failures, setup percentiles, queue and gates", %{runner: runner, user: user} do
      since = DateTime.add(DateTime.utc_now(), -1, :day)

      assert %{runs: 0, failure_rate: nil, setup_p50_ms: nil} =
               RunnerTelemetry.run_stats(runner, since)

      finished(runner, user, :succeeded,
        setup: %{"duration_ms" => 1_000},
        insights: %{"timing" => %{"gates" => 400}}
      )

      finished(runner, user, :succeeded, setup: %{"duration_ms" => 3_000})
      finished(runner, user, :failed, setup: %{"duration_ms" => 2_000})
      finished(runner, user, :canceled, [])

      stats = RunnerTelemetry.run_stats(runner, since)
      assert stats.runs == 3
      assert stats.failed == 1
      assert_in_delta stats.failure_rate, 1 / 3, 0.0001
      assert stats.setup_p50_ms == 2_000
      assert stats.setup_p95_ms == 2_900
      assert stats.queue_p50_ms == 2_000
      assert stats.gates_p50_ms == 400

      other =
        runner_fixture(Repo.get!(PipeMaestro.Workspaces.Workspace, runner.workspace_id), user)
        |> elem(0)

      rates = RunnerTelemetry.failure_rates([runner, other], since)
      assert_in_delta rates[runner.id], 1 / 3, 0.0001
      assert rates[other.id] == nil
      assert %Job{} = Repo.get_by!(Job, runner_id: runner.id, status: :canceled)
    end
  end
end
