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
                 "num_turns" => 3
               })

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
end
