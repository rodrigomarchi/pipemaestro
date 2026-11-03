defmodule ClaudeControlPlane.JobsTest do
  use ClaudeControlPlane.DataCase, async: true

  import ClaudeControlPlane.Fixtures

  alias ClaudeControlPlane.{Jobs, Runners}
  alias ClaudeControlPlane.Jobs.{Event, Job}

  setup do
    workspace = workspace_fixture()
    user = member_fixture(workspace)
    {runner, _token} = runner_fixture(workspace, user)
    %{workspace: workspace, user: user, runner: runner}
  end

  describe "create_job/3" do
    test "queues the job and hands it to the runner", ctx do
      :ok = Jobs.subscribe({:runner, ctx.runner.id})
      :ok = Jobs.subscribe({:workspace, ctx.workspace.id})

      assert {:ok, %Job{status: :queued} = job} =
               Jobs.create_job(ctx.user, ctx.workspace, %{
                 "prompt" => "diga oi",
                 "runner_id" => ctx.runner.id
               })

      assert job.runner.id == ctx.runner.id
      assert job.created_by_user.id == ctx.user.id
      assert_receive {:job_assign, %Job{id: id}} when id == job.id
      assert_receive {:job_updated, %Job{id: ^id}}
      assert [%Job{id: ^id}] = Jobs.list_jobs(ctx.workspace)
      assert Jobs.get_job!(ctx.workspace, id).prompt == "diga oi"
    end

    test "requires a prompt and a runner", ctx do
      assert {:error, changeset} = Jobs.create_job(ctx.user, ctx.workspace, %{})
      assert %{prompt: [_], runner_id: [_]} = errors_on(changeset)
    end

    test "refuses a runner of another workspace or a revoked one", ctx do
      other = workspace_fixture()
      {foreign, _token} = runner_fixture(other, member_fixture(other))

      assert {:error, changeset} =
               Jobs.create_job(ctx.user, ctx.workspace, %{
                 "prompt" => "x",
                 "runner_id" => foreign.id
               })

      assert %{runner_id: ["não é um runner ativo deste workspace"]} = errors_on(changeset)

      {:ok, revoked} = Runners.revoke_runner(ctx.runner)

      assert {:error, _changeset} =
               Jobs.create_job(ctx.user, ctx.workspace, %{
                 "prompt" => "x",
                 "runner_id" => revoked.id
               })
    end

    test "a workspace does not see another's jobs", ctx do
      job = job_fixture(ctx.runner, ctx.user)
      other = workspace_fixture()

      assert Jobs.list_jobs(other) == []
      assert_raise Ecto.NoResultsError, fn -> Jobs.get_job!(other, job.id) end
    end
  end

  describe "a run reported by the runner" do
    test "started, events, finished", ctx do
      job = job_fixture(ctx.runner, ctx.user)
      :ok = Jobs.subscribe({:job, job.id})

      assert {:ok, %Job{status: :running, started_at: %DateTime{}}} =
               Jobs.mark_started(ctx.runner, job.id)

      assert Jobs.mark_started(ctx.runner, job.id) == {:error, :not_queued}

      event = %{"seq" => 1, "type" => "assistant_text", "data" => %{"text" => "oi"}}
      assert {:ok, %Event{seq: 1}} = Jobs.append_event(ctx.runner, job.id, event)
      assert_receive {:job_event, %Event{seq: 1}}
      assert {:ok, :duplicate} = Jobs.append_event(ctx.runner, job.id, event)

      assert {:error, %Ecto.Changeset{}} =
               Jobs.append_event(ctx.runner, job.id, %{"seq" => 2, "type" => "nope"})

      assert [%Event{seq: 1, data: %{"text" => "oi"}}] = Jobs.list_events(job)

      assert {:ok, %Job{status: :succeeded} = finished} =
               Jobs.finish_job(ctx.runner, job.id, %{
                 "status" => "succeeded",
                 "exit_code" => 0,
                 "result" => "oi",
                 "cost_usd" => 0.0037,
                 "duration_ms" => 5591,
                 "num_turns" => 3,
                 "setup" => %{"copied" => ["deps"], "duration_ms" => 812},
                 "changes" => %{
                   "files" => [%{"path" => "lib/a.ex", "added" => 2, "removed" => 1}],
                   "patch" => "+x",
                   "truncated" => false,
                   "task_files" => []
                 }
               })

      assert %{"files" => [%{"path" => "lib/a.ex"}]} = finished.changes

      assert finished.setup == %{"copied" => ["deps"], "duration_ms" => 812}
      assert Decimal.equal?(finished.cost_usd, Decimal.from_float(0.0037))
      assert %DateTime{} = finished.finished_at
      assert_receive {:job_updated, %Job{status: :succeeded}}

      assert Jobs.finish_job(ctx.runner, job.id, %{"status" => "failed"}) == {:error, :finished}
    end

    test "refuses an unknown status", ctx do
      job = job_fixture(ctx.runner, ctx.user)

      assert {:error, %Ecto.Changeset{}} =
               Jobs.finish_job(ctx.runner, job.id, %{"status" => "running"})
    end

    test "a runner cannot touch another runner's job", ctx do
      job = job_fixture(ctx.runner, ctx.user)
      {other_runner, _token} = runner_fixture(ctx.workspace, ctx.user)

      assert Jobs.mark_started(other_runner, job.id) == {:error, :not_found}
      assert Jobs.append_event(other_runner, job.id, %{}) == {:error, :not_found}
      assert Jobs.finish_job(other_runner, job.id, %{}) == {:error, :not_found}
      assert Jobs.mark_started(ctx.runner, "not-a-uuid") == {:error, :not_found}
    end
  end

  describe "what a run reports for auditing" do
    setup ctx do
      {:ok, job} =
        Jobs.create_job(ctx.user, ctx.workspace, %{"prompt" => "oi", "runner_id" => ctx.runner.id})

      {:ok, _} = Jobs.mark_started(ctx.runner, job.id)
      %{job: job}
    end

    test "the outcome keeps the session, tokens, models, environment and stderr", ctx do
      {:ok, job} =
        Jobs.finish_job(ctx.runner, ctx.job.id, %{
          "status" => "succeeded",
          "session_id" => "s-1",
          "cli_version" => "2.1.317",
          "model" => "claude-haiku-5-5",
          "stop_reason" => "end_turn",
          "result_subtype" => "success",
          "duration_api_ms" => 4054,
          "ttft_ms" => 1295,
          "wall_ms" => 5200,
          "usage" => %{
            "fresh_input" => 6,
            "cache_read" => 60_503,
            "cache_creation" => 14_376,
            "output" => 567,
            "thinking" => 118
          },
          "model_usage" => %{"claude-haiku-5-5" => %{"cost_usd" => 0.0037}},
          "permission_denials" => [%{"tool_name" => "Bash", "input" => "rm -rf /"}],
          "subagents" => %{"spawned" => 1, "completed" => 1, "failed" => 0},
          "environment" => %{"tools" => ["Bash"], "mcp_servers" => [%{"name" => "grafana"}]},
          "stderr" => "aviso"
        })

      assert job.session_id == "s-1"
      assert job.cli_version == "2.1.317"
      assert job.model == "claude-haiku-5-5"
      assert {job.duration_api_ms, job.ttft_ms, job.wall_ms} == {4054, 1295, 5200}

      assert {job.input_tokens, job.cache_read_tokens, job.cache_creation_tokens,
              job.output_tokens, job.thinking_tokens} == {6, 60_503, 14_376, 567, 118}

      assert job.model_usage["claude-haiku-5-5"]["cost_usd"] == 0.0037
      assert [%{"tool_name" => "Bash"}] = job.permission_denials
      assert job.subagents["spawned"] == 1
      assert job.environment["tools"] == ["Bash"]
      assert job.stderr == "aviso"
    end

    test "telemetry is stored and its metrics summed, also after the job ended", ctx do
      records = [
        %{
          "name" => "api_request",
          "at" => "2026-11-03T21:28:13.171Z",
          "attrs" => %{"duration_ms" => 1913, "model" => "claude-haiku-5-5"}
        },
        %{
          "name" => "metric:lines_of_code",
          "at" => "2026-11-03T21:28:14.000Z",
          "attrs" => %{"type" => "added", "value" => 5}
        },
        %{
          "name" => "metric:commit",
          "at" => "2026-11-03T21:28:14.000Z",
          "attrs" => %{"value" => 1}
        },
        %{"name" => "plugin_loaded", "at" => "2026-11-03T21:28:14.000Z", "attrs" => %{}},
        %{"name" => "api_error", "at" => 123, "attrs" => %{}},
        "não é um registro"
      ]

      :ok = Jobs.subscribe({:job, ctx.job.id})
      assert {:ok, 3} = Jobs.record_telemetry(ctx.runner, ctx.job.id, records)
      job_id = ctx.job.id
      assert_receive {:job_telemetry, ^job_id}
      {:ok, _} = Jobs.finish_job(ctx.runner, ctx.job.id, %{"status" => "succeeded"})

      late = [
        %{
          "name" => "metric:lines_of_code",
          "at" => "2026-11-03T21:28:15.000Z",
          "attrs" => %{"type" => "removed", "value" => 2}
        },
        %{
          "name" => "metric:lines_of_code",
          "at" => "2026-11-03T21:28:15.500Z",
          "attrs" => %{"type" => "added", "value" => 1}
        }
      ]

      assert {:ok, 2} = Jobs.record_telemetry(ctx.runner, ctx.job.id, late)

      assert {:ok, 1} =
               Jobs.record_telemetry(ctx.runner, ctx.job.id, [
                 %{"name" => "api_error", "at" => "2026-11-03T21:28:16Z", "attrs" => "x"}
               ])

      job = Jobs.get_job!(ctx.workspace, ctx.job.id)
      assert job.telemetry_totals == %{"lines_added" => 6, "lines_removed" => 2, "commits" => 1}

      assert [%{name: "api_request", attrs: %{"duration_ms" => 1913}} | _] =
               Jobs.list_telemetry(job)

      assert length(Jobs.list_telemetry(job)) == 6
    end

    test "a run's tokens and how much of its input came from the cache" do
      job = %Job{
        input_tokens: 100,
        cache_read_tokens: 2_900,
        cache_creation_tokens: 0,
        output_tokens: 500
      }

      assert Job.tokens(job) == 3_500
      assert Job.cache_hit(job) == 0.97
      assert Job.tokens(%Job{}) == 0
      assert Job.cache_hit(%Job{}) == nil
    end

    test "a runner cannot report telemetry for another's job", ctx do
      {other, _token} = runner_fixture(ctx.workspace, ctx.user)
      assert Jobs.record_telemetry(other, ctx.job.id, []) == {:error, :not_found}
    end
  end

  describe "request_cancel/1" do
    test "a queued job is canceled at once and its runner told", ctx do
      job = job_fixture(ctx.runner, ctx.user)
      :ok = Jobs.subscribe({:runner, ctx.runner.id})

      assert {:ok, %Job{status: :canceled}} = Jobs.request_cancel(job)
      assert_receive {:job_cancel, id} when id == job.id
      assert Jobs.queued_for_runner(ctx.runner) == []
    end

    test "a running job waits for the runner to report the end", ctx do
      job = job_fixture(ctx.runner, ctx.user)
      {:ok, running} = Jobs.mark_started(ctx.runner, job.id)
      :ok = Jobs.subscribe({:runner, ctx.runner.id})

      assert {:ok, %Job{status: :running, cancel_requested_at: %DateTime{}} = job} =
               Jobs.request_cancel(running)

      assert_receive {:job_cancel, _id}

      {:ok, job} = Jobs.finish_job(ctx.runner, job.id, %{"status" => "canceled"})
      assert Jobs.request_cancel(job) == {:error, :finished}
    end
  end

  describe "reconcile/2" do
    test "fails running jobs the runner lost and returns the queued ones", ctx do
      lost = job_fixture(ctx.runner, ctx.user)
      alive = job_fixture(ctx.runner, ctx.user)
      queued = job_fixture(ctx.runner, ctx.user)
      {:ok, _} = Jobs.mark_started(ctx.runner, lost.id)
      {:ok, _} = Jobs.mark_started(ctx.runner, alive.id)

      assert [%Job{id: queued_id}] = Jobs.reconcile(ctx.runner, [alive.id, "garbage"])
      assert queued_id == queued.id

      assert %Job{status: :failed, error: "O runner" <> _} = Jobs.get_job!(ctx.workspace, lost.id)
      assert %Job{status: :running} = Jobs.get_job!(ctx.workspace, alive.id)
    end
  end

  describe "load_by_runner/1" do
    test "counts each runner's running and queued jobs", ctx do
      {other, _token} = runner_fixture(ctx.workspace, ctx.user)
      running = job_fixture(ctx.runner, ctx.user)
      _queued = job_fixture(ctx.runner, ctx.user)
      done = job_fixture(ctx.runner, ctx.user)
      {:ok, _} = Jobs.mark_started(ctx.runner, running.id)
      {:ok, _} = Jobs.mark_started(ctx.runner, done.id)
      {:ok, _} = Jobs.finish_job(ctx.runner, done.id, %{"status" => "succeeded"})
      elsewhere = workspace_fixture()
      stranger = member_fixture(elsewhere)
      {foreign, _token} = runner_fixture(elsewhere, stranger)
      _foreign_job = job_fixture(foreign, stranger)

      assert Jobs.load_by_runner(ctx.workspace) == %{ctx.runner.id => %{running: 1, queued: 1}}
      refute Map.has_key?(Jobs.load_by_runner(ctx.workspace), other.id)
    end
  end

  describe "active_for_runner/1" do
    test "the runner's running jobs, then the ones waiting, oldest first", ctx do
      running = job_fixture(ctx.runner, ctx.user)
      waiting = job_fixture(ctx.runner, ctx.user)
      done = job_fixture(ctx.runner, ctx.user)
      {:ok, _} = Jobs.mark_started(ctx.runner, running.id)
      {:ok, _} = Jobs.mark_started(ctx.runner, done.id)
      {:ok, _} = Jobs.finish_job(ctx.runner, done.id, %{"status" => "succeeded"})

      assert Enum.map(Jobs.active_for_runner(ctx.runner), &{&1.id, &1.status}) == [
               {running.id, :running},
               {waiting.id, :queued}
             ]
    end
  end
end
