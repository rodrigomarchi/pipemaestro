defmodule PipeMaestro.MaintenanceTest do
  use PipeMaestro.DataCase, async: true

  import PipeMaestro.Fixtures

  alias PipeMaestro.{Audit, FakeForgejo, Jobs, Maintenance, Repo, Runners, RunnerTelemetry}
  alias PipeMaestro.Integrations.{Delivery, Ingest}
  alias PipeMaestro.Jobs.Event
  alias PipeMaestro.Runners.DeviceAuthorization

  test "removes stale sign-in requests, old job events and old audit entries" do
    workspace = workspace_fixture()
    user = member_fixture(workspace)
    {runner, _token} = runner_fixture(workspace, user)

    {:ok, stale, _code, _user_code} = Runners.start_device_authorization(hello_fixture())

    stale
    |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(:second), -2, :day))
    |> Repo.update!()

    {:ok, fresh, _code, _user_code} = Runners.start_device_authorization(hello_fixture())

    old_job = job_fixture(runner, user)
    {:ok, _} = Jobs.mark_started(runner, old_job.id)

    {:ok, _} =
      Jobs.append_event(runner, old_job.id, %{
        "seq" => 1,
        "type" => "assistant_text",
        "data" => %{"text" => "x"}
      })

    {:ok, 1} =
      Jobs.record_telemetry(runner, old_job.id, [
        %{"name" => "api_request", "at" => "2026-10-01T10:00:00Z", "attrs" => %{}}
      ])

    {:ok, _} = Jobs.finish_job(runner, old_job.id, %{"status" => "succeeded"})

    old_job
    |> Ecto.Changeset.change(finished_at: DateTime.add(DateTime.utc_now(:second), -40, :day))
    |> Repo.update!()

    new_job = job_fixture(runner, user)
    {:ok, _} = Jobs.mark_started(runner, new_job.id)

    {:ok, _} =
      Jobs.append_event(runner, new_job.id, %{
        "seq" => 1,
        "type" => "assistant_text",
        "data" => %{"text" => "y"}
      })

    old_audit = Audit.list_events(workspace) |> hd()

    old_audit
    |> Ecto.Changeset.change(inserted_at: DateTime.add(DateTime.utc_now(), -400, :day))
    |> Repo.update!()

    assert %{device_authorizations: 1, job_events: 1, job_telemetry: 1, audit_events: 1} =
             Maintenance.run(DateTime.utc_now())

    refute Repo.get(DeviceAuthorization, stale.id)
    assert Repo.get(DeviceAuthorization, fresh.id)
    assert [%Event{}] = Jobs.list_events(new_job)
    assert Jobs.list_events(old_job) == []
    assert job_telemetry(old_job) == []
    # The job itself (its outcome and cost) stays.
    assert Jobs.get_job!(workspace, old_job.id).status == :succeeded
  end

  test "removes the integrations' deliveries past their retention" do
    workspace = workspace_fixture()
    FakeForgejo.start()
    connection = connection_fixture(workspace)

    for {id, days} <- [{"velha", 40}, {"nova", 1}] do
      {:ok, delivery} =
        Ingest.ingest_event(connection, id, "push", %{})

      delivery
      |> Ecto.Changeset.change(inserted_at: DateTime.add(DateTime.utc_now(), -days, :day))
      |> Repo.update!()
    end

    assert %{deliveries: 1} = Maintenance.run(DateTime.utc_now())

    assert [%{external_id: "nova"}] =
             Repo.all(Delivery)
  end

  test "removes the runners' health samples past their retention" do
    workspace = workspace_fixture()
    {runner, _token} = runner_fixture(workspace, member_fixture(workspace))
    now = DateTime.utc_now()

    for days <- [8, 1] do
      at = DateTime.add(now, -days, :day) |> DateTime.to_iso8601()
      {:ok, _} = RunnerTelemetry.record_health(runner, %{"at" => at, "cpu_pct" => 1})
    end

    assert %{health_samples: 1} = Maintenance.run(now)
    assert %{health_samples: 0} = Maintenance.run(now)
    assert RunnerTelemetry.latest_health(runner)
  end
end
