defmodule ClaudeControlPlane.MaintenanceTest do
  use ClaudeControlPlane.DataCase, async: true

  import ClaudeControlPlane.Fixtures

  alias ClaudeControlPlane.{Audit, Jobs, Maintenance, Repo, Runners}
  alias ClaudeControlPlane.Jobs.Event
  alias ClaudeControlPlane.Runners.DeviceAuthorization

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
    assert Jobs.list_telemetry(old_job) == []
    # The job itself (its outcome and cost) stays.
    assert Jobs.get_job!(workspace, old_job.id).status == :succeeded
  end
end
