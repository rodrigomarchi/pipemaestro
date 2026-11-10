defmodule PipeMaestro.MaintenanceTest do
  use PipeMaestro.DataCase, async: true

  import PipeMaestro.Fixtures

  import Ecto.Query

  alias PipeMaestro.{
    Audit,
    FakeForgejo,
    Insights,
    Jobs,
    Maintenance,
    Repo,
    Runners,
    RunnerTelemetry,
    Tasks,
    Usage,
    Workspaces
  }

  alias PipeMaestro.Integrations.{Delivery, Ingest}
  alias PipeMaestro.Jobs.{Event, Files, Job, JobFile}
  alias PipeMaestro.Runners.DeviceAuthorization

  test "removes stale sign-in requests, old job events and old audit entries" do
    workspace = workspace_fixture()

    {:ok, workspace} =
      Workspaces.update_workspace(workspace, %{agent_events_after_retention: "delete"})

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

  describe "the agent events' retention, per workspace" do
    setup do
      workspace = workspace_fixture()
      user = member_fixture(workspace)
      {runner, _token} = runner_fixture(workspace, user)
      %{workspace: workspace, user: user, runner: runner}
    end

    @events [
      {"system",
       %{"text" => "Sessão iniciada", "model" => "claude-sonnet-5-5", "cwd" => "/home/x/app"}},
      {"assistant_text", %{"text" => "Vou ler o código", "usage" => %{"output" => 3}}},
      {"tool_use",
       %{
         "id" => "t1",
         "name" => "Read",
         "text" => "lib/segredo.ex",
         "input" => %{"file_path" => "lib/segredo.ex"}
       }},
      {"tool_result",
       %{"tool_use_id" => "t1", "text" => "defmodule Segredo do", "is_error" => false}},
      {"result",
       %{
         "text" => "Pronto",
         "is_error" => false,
         "subtype" => "success",
         "cost_usd" => 0.42,
         "duration_ms" => 1200,
         "structured_output" => %{"resumo" => "segredo"}
       }}
    ]

    @stripped [
      {1, "system", %{"model" => "claude-sonnet-5-5"}},
      {2, "assistant_text", %{"usage" => %{"output" => 3}}},
      {3, "tool_use", %{"id" => "t1", "name" => "Read"}},
      {4, "tool_result", %{"tool_use_id" => "t1", "is_error" => false}},
      {5, "result",
       %{"is_error" => false, "subtype" => "success", "cost_usd" => 0.42, "duration_ms" => 1200}}
    ]

    defp policy(workspace, attrs) do
      {:ok, workspace} = Workspaces.update_workspace(workspace, attrs)
      workspace
    end

    # A job that ran the events above, sent a record and ended `days` ago.
    defp ended_job(runner, user, days) do
      job = job_fixture(runner, user)
      {:ok, _} = Jobs.mark_started(runner, job.id)

      for {{type, data}, seq} <- Enum.with_index(@events, 1) do
        {:ok, _} =
          Jobs.append_event(runner, job.id, %{"seq" => seq, "type" => type, "data" => data})
      end

      {:ok, 1} =
        Jobs.record_telemetry(runner, job.id, [
          %{"name" => "api_request", "at" => "2026-10-01T10:00:00Z", "attrs" => %{}}
        ])

      {:ok, _} =
        Jobs.finish_job(runner, job.id, %{
          "status" => "succeeded",
          "cost_usd" => 0.42,
          "duration_ms" => 1200
        })

      job
      |> Ecto.Changeset.change(finished_at: DateTime.add(DateTime.utc_now(:second), -days, :day))
      |> Repo.update!()
    end

    defp events(job), do: job |> Jobs.list_events() |> Enum.map(&{&1.seq, &1.type, &1.data})

    test "by default, past 30 days, keeps every event with only its metadata", ctx do
      job = ended_job(ctx.runner, ctx.user, 31)
      recent = ended_job(ctx.runner, ctx.user, 29)

      assert %{job_events: 0, job_events_stripped: 5, job_telemetry: 1} =
               Maintenance.run(DateTime.utc_now())

      assert events(job) == @stripped
      assert job_telemetry(job) == []
      assert %DateTime{} = Map.get(Repo.reload!(job), :events_pruned_at)

      assert length(events(recent)) == 5
      assert hd(events(recent)) |> elem(2) |> Map.has_key?("text")
      assert job_telemetry(recent) != []
      assert Map.get(Repo.reload!(recent), :events_pruned_at) == nil
    end

    test "a job already pruned is not touched again", ctx do
      job = ended_job(ctx.runner, ctx.user, 40)

      Maintenance.run(DateTime.utc_now())
      pruned_at = Map.get(Repo.reload!(job), :events_pruned_at)
      assert %DateTime{} = pruned_at

      assert %{job_events: 0, job_events_stripped: 0, job_telemetry: 0} =
               Maintenance.run(DateTime.add(DateTime.utc_now(), 1, :day))

      assert events(job) == @stripped
      assert Map.get(Repo.reload!(job), :events_pruned_at) == pruned_at
    end

    test "with delete, the events go, as do the records", ctx do
      policy(ctx.workspace, %{agent_events_after_retention: "delete"})
      job = ended_job(ctx.runner, ctx.user, 31)

      assert %{job_events: 5, job_events_stripped: 0, job_telemetry: 1} =
               Maintenance.run(DateTime.utc_now())

      assert Jobs.list_events(job) == []
      assert job_telemetry(job) == []
      assert %DateTime{} = Map.get(Repo.reload!(job), :events_pruned_at)
      # The job itself (its outcome and cost) stays.
      assert Repo.reload!(job).status == :succeeded
    end

    test "each workspace by its own retention, in the same run", ctx do
      policy(ctx.workspace, %{agent_events_retention_days: 7})
      short = ended_job(ctx.runner, ctx.user, 10)

      other = policy(workspace_fixture(), %{agent_events_retention_days: 60})
      other_user = member_fixture(other)
      {other_runner, _token} = runner_fixture(other, other_user)
      long = ended_job(other_runner, other_user, 40)

      Maintenance.run(DateTime.utc_now())

      assert events(short) == @stripped
      assert length(events(long)) == 5
      assert Map.get(Repo.reload!(long), :events_pruned_at) == nil
      assert job_telemetry(long) != []
    end

    test "at most :batch jobs per run; the rest go on the next", ctx do
      jobs = for _ <- 1..3, do: ended_job(ctx.runner, ctx.user, 40)

      Maintenance.run(DateTime.utc_now(), batch: 2)
      pruned = Enum.count(jobs, &Map.get(Repo.reload!(&1), :events_pruned_at))
      assert pruned == 2

      Maintenance.run(DateTime.utc_now(), batch: 2)
      assert Enum.all?(jobs, &Map.get(Repo.reload!(&1), :events_pruned_at))
    end

    test "a job of the old retention, with nothing left, keeps its summary", ctx do
      job = ended_job(ctx.runner, ctx.user, 40)
      summary = Repo.reload!(job).insights
      assert %{} = summary

      Repo.delete_all(from e in Event, where: e.job_id == ^job.id)
      Repo.delete_all(from t in PipeMaestro.Jobs.Telemetry, where: t.job_id == ^job.id)

      Maintenance.run(DateTime.utc_now())

      assert Repo.reload!(job).insights == summary
    end

    test "a pruned job without a summary is not summarized from what is left", ctx do
      job = ended_job(ctx.runner, ctx.user, 40)
      Maintenance.run(DateTime.utc_now())
      job |> Repo.reload!() |> Ecto.Changeset.change(insights: nil) |> Repo.update!()

      assert %{summarized: 0} = Maintenance.run(DateTime.utc_now())
      assert Repo.reload!(job).insights == nil
    end

    test "usage, the audit and the run's insights stay the same", ctx do
      runner = with_directories(ctx.runner, [%{"name" => "app", "git" => true}])

      {:ok, task} =
        Tasks.create_task(ctx.user, ctx.workspace, %{
          "title" => "T",
          "prompt" => "p",
          "pipeline_id" => pipeline_fixture(ctx.workspace).id,
          "project_id" => project_fixture(runner, "app").id
        })

      [stage_run | _] = Tasks.get_task!(ctx.workspace, task.id).stage_runs
      job = stage_run.job
      {:ok, _} = Jobs.mark_started(runner, job.id)

      for {{type, data}, seq} <- Enum.with_index(@events, 1) do
        {:ok, _} =
          Jobs.append_event(runner, job.id, %{"seq" => seq, "type" => type, "data" => data})
      end

      {:ok, _} =
        Jobs.finish_job(runner, job.id, %{
          "status" => "succeeded",
          "exit_code" => 0,
          "structured_output" => %{"status" => "ok", "resumo" => "ok"},
          "artifact" => "# a",
          "cost_usd" => 0.5,
          "duration_ms" => 1_000,
          "usage" => %{
            "fresh_input" => 10,
            "cache_read" => 70,
            "cache_creation" => 10,
            "output" => 10
          }
        })

      since = DateTime.add(DateTime.utc_now(), -90, :day)
      job = Repo.get!(Job, job.id)

      job
      |> Ecto.Changeset.change(finished_at: DateTime.add(DateTime.utc_now(:second), -40, :day))
      |> Repo.update!()

      usage = Usage.report(ctx.workspace, since)
      audit = length(Audit.list_events(ctx.workspace))
      insights = Insights.job(Repo.get!(Job, job.id))

      Maintenance.run(DateTime.utc_now())
      job = Repo.get!(Job, job.id)
      assert %DateTime{} = Map.get(job, :events_pruned_at)

      assert Usage.report(ctx.workspace, since) == usage
      assert length(Audit.list_events(ctx.workspace)) == audit
      assert Insights.job(job) == insights

      # The kept summary is final: writing it again does not read the pruned events.
      kept = job.insights
      Insights.store_summary(job)
      assert Repo.get!(Job, job.id).insights == kept
    end
  end

  describe "the files' retention" do
    test "empties the files past their workspace's retention and says how many" do
      workspace = workspace_fixture()
      {:ok, _} = Workspaces.update_workspace(workspace, %{job_files_retention_days: 10})
      user = member_fixture(workspace)
      {runner, _token} = runner_fixture(workspace, user)
      job = job_fixture(runner, user)

      {:ok, file} = Files.store(runner, job.id, "a.csv", "a,b\n")
      at = DateTime.add(DateTime.utc_now(:second), -11, :day)
      Repo.update_all(from(f in JobFile, where: f.id == ^file.id), set: [inserted_at: at])

      assert %{job_files: 1} = Maintenance.run(DateTime.utc_now())
      assert Files.get_for_download(workspace, file.id).content == nil
    end

    test "by default, no file loses its content, however old" do
      workspace = workspace_fixture()
      user = member_fixture(workspace)
      {runner, _token} = runner_fixture(workspace, user)
      job = job_fixture(runner, user)

      {:ok, file} = Files.store(runner, job.id, "a.csv", "a,b\n")
      at = DateTime.add(DateTime.utc_now(:second), -4000, :day)
      Repo.update_all(from(f in JobFile, where: f.id == ^file.id), set: [inserted_at: at])

      assert %{job_files: 0} = Maintenance.run(DateTime.utc_now())
      assert Files.get_for_download(workspace, file.id).content == "a,b\n"
    end
  end
end
