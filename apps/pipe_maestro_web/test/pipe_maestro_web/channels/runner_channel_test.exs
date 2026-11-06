defmodule PipeMaestroWeb.RunnerChannelTest do
  use PipeMaestroWeb.ChannelCase, async: false

  alias PipeMaestro.{FakeForgejo, Integrations, Jobs, Repo, Runners, RunnerTelemetry, Tasks}
  alias PipeMaestro.Jobs.Job
  alias PipeMaestro.Runners.Runner
  alias PipeMaestroProtocol.Hello
  alias PipeMaestroWeb.{RunnerChannel, RunnerSocket, RunnerStatus}

  setup do
    workspace = workspace_fixture()
    user = member_fixture(workspace)
    {runner, token} = runner_fixture(workspace, user, %{name: "build-01"})
    %{workspace: workspace, runner: runner, token: token}
  end

  defp params(token, version \\ PipeMaestroProtocol.version()) do
    %{"token" => token, "protocol_version" => to_string(version)}
  end

  describe "connect" do
    test "accepts the runner's token", %{runner: runner, token: token} do
      assert {:ok, socket} = connect(RunnerSocket, params(token))
      assert socket.assigns.runner.id == runner.id
      assert RunnerSocket.id(socket) == "runner_socket:" <> runner.id
    end

    test "refuses a wrong token, a revoked runner or an unsupported version", %{
      runner: runner,
      token: token
    } do
      assert connect(RunnerSocket, params("cpr_wrong")) == :error
      assert connect(RunnerSocket, params(token, 999)) == :error
      assert connect(RunnerSocket, params(token, "abc")) == :error
      assert connect(RunnerSocket, %{}) == :error

      {:ok, _} = Runners.revoke_runner(runner)
      assert connect(RunnerSocket, params(token)) == :error
    end
  end

  describe "join" do
    setup %{token: token} do
      {:ok, socket} = connect(RunnerSocket, params(token))
      %{socket: socket}
    end

    test "records the hello and tracks the runner online until it leaves", %{
      socket: socket,
      runner: runner,
      workspace: workspace
    } do
      RunnerStatus.subscribe(workspace.id)
      hello = hello_fixture(%{labels: ["docker", "linux"], capacity: 8})

      {:ok, reply, channel} =
        subscribe_and_join(socket, RunnerChannel, "runner:" <> runner.id, Hello.to_map(hello))

      assert reply["name"] == "build-01"
      assert_receive :runners_changed
      assert MapSet.member?(RunnerStatus.online_ids(workspace.id), runner.id)

      assert %{labels: ["docker", "linux"], capacity: 8} =
               Runners.get_runner!(workspace, runner.id)

      Process.unlink(channel.channel_pid)
      ref = Process.monitor(channel.channel_pid)
      close(channel)
      assert_receive {:DOWN, ^ref, _, _, _}
      assert_receive %Phoenix.Socket.Broadcast{event: "presence_diff"}
      refute MapSet.member?(RunnerStatus.online_ids(workspace.id), runner.id)
    end

    test "refuses another runner's topic or an invalid hello", %{socket: socket, runner: runner} do
      hello = Hello.to_map(hello_fixture())

      assert {:error, %{"reason" => "unauthorized"}} =
               subscribe_and_join(socket, RunnerChannel, "runner:someone-else", hello)

      assert {:error, %{"reason" => "invalid_hello"}} =
               subscribe_and_join(socket, RunnerChannel, "runner:" <> runner.id, %{})
    end

    test "revoking tells the runner's socket to disconnect", %{
      socket: socket,
      runner: runner,
      workspace: workspace
    } do
      RunnerStatus.subscribe(workspace.id)

      {:ok, _reply, channel} =
        subscribe_and_join(
          socket,
          RunnerChannel,
          "runner:" <> runner.id,
          Hello.to_map(hello_fixture())
        )

      # The channel finishes joining (tracking, notifying) before it is closed.
      assert_receive :runners_changed

      @endpoint.subscribe(RunnerStatus.socket_id(runner.id))
      RunnerStatus.disconnect(runner)
      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}

      Process.unlink(channel.channel_pid)
      ref = Process.monitor(channel.channel_pid)
      close(channel)
      assert_receive {:DOWN, ^ref, _, _, _}
    end
  end

  describe "sessions" do
    setup %{token: token} do
      {:ok, socket} = connect(RunnerSocket, params(token))
      Process.put(:token, token)
      %{socket: socket}
    end

    defp params_for(_runner), do: params(Process.get(:token))

    defp join_and_close(socket, runner, before_close) do
      {:ok, _reply, channel} =
        subscribe_and_join(
          socket,
          RunnerChannel,
          "runner:" <> runner.id,
          Hello.to_map(hello_fixture())
        )

      before_close.()
      Process.unlink(channel.channel_pid)
      ref = Process.monitor(channel.channel_pid)
      close(channel)
      assert_receive {:DOWN, ^ref, _, _, _}
    end

    defp sessions(runner), do: RunnerTelemetry.sessions(runner, ~U[2000-01-01 00:00:00Z])

    test "a join opens a session and its end closes it", %{socket: socket, runner: runner} do
      join_and_close(socket, runner, fn ->
        assert [%{ended_at: nil, runner_version: version}] = sessions(runner)
        assert version == hello_fixture().runner_version
      end)

      assert [%{end_reason: "closed"}] = sessions(runner)
    end

    test "a revoked runner's session ends as revoked", %{socket: socket, runner: runner} do
      join_and_close(socket, runner, fn -> {:ok, _} = Runners.revoke_runner(runner) end)
      assert [%{end_reason: "revoked"}] = sessions(runner)
    end

    test "health samples are stored and passed on to the runner's screens", %{
      socket: socket,
      runner: runner
    } do
      {:ok, _reply, channel} =
        subscribe_and_join(
          socket,
          RunnerChannel,
          "runner:" <> runner.id,
          Hello.to_map(hello_fixture())
        )

      RunnerStatus.subscribe_telemetry(runner.id)
      sample = %{"at" => DateTime.to_iso8601(DateTime.utc_now()), "cpu_pct" => 42}
      ref = push(channel, "runner:health", sample)
      assert_reply ref, :ok
      assert_receive {:runner_telemetry, :health}
      assert %{cpu_pct: 42.0} = RunnerTelemetry.latest_health(runner)

      ref = push(channel, "runner:health", %{"cpu_pct" => 1})
      assert_reply ref, :error, %{"reason" => "invalid"}
    end

    test "the runner's log is stored; the join says whether lines are kept", %{
      socket: socket,
      runner: runner,
      workspace: workspace
    } do
      {:ok, reply, channel} =
        subscribe_and_join(
          socket,
          RunnerChannel,
          "runner:" <> runner.id,
          Hello.to_map(hello_fixture())
        )

      assert reply["telemetry"] == %{"logs" => true}
      RunnerStatus.subscribe_telemetry(runner.id)

      line =
        PipeMaestroProtocol.RunnerLog.line(DateTime.utc_now(), "info", "Online como build-01")

      ref = push(channel, "runner:log", %{"lines" => [line]})
      assert_reply ref, :ok
      assert_receive {:runner_telemetry, :log}
      assert [%{message: "Online como build-01"}] = RunnerTelemetry.log_lines(runner)

      ref = push(channel, "runner:log", %{"lines" => [%{"level" => "info"}]})
      assert_reply ref, :error, %{"reason" => "invalid"}

      workspace |> Ecto.Changeset.change(runner_log_retention_days: 0) |> Repo.update!()
      {:ok, socket} = connect(RunnerSocket, params_for(runner))

      {:ok, reply, _channel} =
        subscribe_and_join(
          socket,
          RunnerChannel,
          "runner:" <> runner.id,
          Hello.to_map(hello_fixture())
        )

      assert reply["telemetry"] == %{"logs" => false}
    end

    test "a screen asks for a diagnosis; the answer is stored", %{
      socket: socket,
      runner: runner,
      workspace: workspace
    } do
      RunnerStatus.subscribe(workspace.id)

      {:ok, _reply, channel} =
        subscribe_and_join(
          socket,
          RunnerChannel,
          "runner:" <> runner.id,
          Hello.to_map(hello_fixture(%{capabilities: ["doctor"]}))
        )

      # The channel listens for requests once it finished joining.
      assert_receive :runners_changed
      RunnerStatus.subscribe_telemetry(runner.id)
      request_id = RunnerStatus.request_doctor(runner.id)
      assert_push "runner:doctor", %{"request_id" => ^request_id}

      checks = [%{key: "git", name: "git", status: :ok, detail: "2.47"}]

      answer =
        PipeMaestroProtocol.RunnerDoctor.to_map(checks, DateTime.utc_now(:second), request_id)

      ref = push(channel, "runner:doctor", answer)
      assert_reply ref, :ok
      assert_receive {:runner_telemetry, :doctor}
      assert %{"request_id" => ^request_id} = Repo.reload!(runner).doctor

      ref = push(channel, "runner:doctor", %{"checks" => []})
      assert_reply ref, :error, %{"reason" => "invalid"}
    end

    test "an invalid hello is recorded as a refusal", %{socket: socket, runner: runner} do
      assert {:error, _} = subscribe_and_join(socket, RunnerChannel, "runner:" <> runner.id, %{})
      assert [%{end_reason: "invalid_hello", ended_at: %DateTime{}}] = sessions(runner)
    end
  end

  describe "jobs" do
    setup %{token: token, workspace: workspace} do
      {:ok, socket} = connect(RunnerSocket, params(token))
      %{socket: socket, user: member_fixture(workspace)}
    end

    # A task from an issue of a linked repository, on a runner joined with `hello`.
    defp linked_task(ctx, hello) do
      FakeForgejo.start()
      connection = connection_fixture(ctx.workspace)

      channel =
        join_runner(
          ctx.socket,
          ctx.runner,
          Map.put(hello, :directories, [%{"name" => "app", "git" => true}])
        )

      Process.put(:channel_pid, channel.channel_pid)
      project = project_fixture(Repo.get!(Runner, ctx.runner.id), "app")

      {:ok, repo} =
        Integrations.link_repo(
          connection,
          ctx.user,
          %{"full_name" => "acme/app", "project_id" => project.id},
          "https://pm.test/hook"
        )

      {:ok, task} =
        Tasks.create_task(
          ctx.user,
          ctx.workspace,
          %{
            "title" => "Corrige",
            "prompt" => "Corrija",
            "pipeline_id" => pipeline_fixture(ctx.workspace).id,
            "project_id" => project.id
          },
          issue: %{linked_repo_id: repo.id, issue_number: 1}
        )

      task
    end

    defp stage_jobs(task),
      do: Enum.filter(Repo.all(Job), &(&1.workspace_id == task.workspace_id))

    defp join_runner(socket, runner, hello_attrs \\ %{}) do
      RunnerStatus.subscribe(runner.workspace_id)
      hello = Hello.to_map(hello_fixture(hello_attrs))

      {:ok, _reply, channel} =
        subscribe_and_join(socket, RunnerChannel, "runner:" <> runner.id, hello)

      assert_receive :runners_changed
      channel
    end

    test "on join, fails lost jobs and hands over the queued ones", ctx do
      lost = job_fixture(ctx.runner, ctx.user)
      {:ok, _} = Jobs.mark_started(ctx.runner, lost.id)
      queued = job_fixture(ctx.runner, ctx.user, %{"prompt" => "fila"})

      join_runner(ctx.socket, ctx.runner)

      assert_push "job:assign", %{"id" => id, "prompt" => "fila"}
      assert id == queued.id
      assert Jobs.get_job!(ctx.workspace, lost.id).status == :failed
    end

    test "a running job the runner still reports survives the join", ctx do
      alive = job_fixture(ctx.runner, ctx.user)
      {:ok, _} = Jobs.mark_started(ctx.runner, alive.id)

      join_runner(ctx.socket, ctx.runner, %{running_job_ids: [alive.id]})

      refute_push "job:assign", _
      assert Jobs.get_job!(ctx.workspace, alive.id).status == :running
    end

    test "a job abandoned while the runner was offline is canceled when it rejoins", ctx do
      abandoned = job_fixture(ctx.runner, ctx.user)
      {:ok, abandoned} = Jobs.mark_started(ctx.runner, abandoned.id)
      {:ok, _job} = Jobs.abandon(abandoned, "Interrompido com o runner offline.")

      join_runner(ctx.socket, ctx.runner, %{running_job_ids: [abandoned.id]})

      job_id = abandoned.id
      assert_push "job:cancel", %{"job_id" => ^job_id}
    end

    test "the workspace's secrets go with each job, and are not stored with it", ctx do
      {:ok, _} = PipeMaestro.Secrets.put(ctx.workspace, "GRAFANA_TOKEN", "glsa_1")
      join_runner(ctx.socket, ctx.runner)

      job = job_fixture(ctx.runner, ctx.user)
      assert_push "job:assign", %{"id" => id, "env" => %{"GRAFANA_TOKEN" => "glsa_1"}}
      assert id == job.id
      refute Map.has_key?(Jobs.get_job!(ctx.workspace, job.id).context, "env")
    end

    test "a proposal goes without the workspace's secrets", ctx do
      {:ok, _} = PipeMaestro.Secrets.put(ctx.workspace, "GRAFANA_TOKEN", "glsa_1")
      join_runner(ctx.socket, ctx.runner)

      {:ok, job} =
        Jobs.create_runner_job(
          ctx.user,
          ctx.workspace,
          %{prompt: "analise", runner_id: ctx.runner.id},
          %{"proposal" => %{"kind" => "task", "input" => %{}}}
        )

      assert_push "job:assign", %{"id" => id} = pushed
      assert id == job.id
      refute Map.has_key?(pushed, "env")
      refute Map.has_key?(pushed, "proposal")
    end

    test "a stage job of a linked task takes the connection's git credential to a runner that knows it",
         ctx do
      task = linked_task(ctx, %{capabilities: ["git_credential"]})

      assert_push "job:assign", %{"git_credential" => credential}

      assert credential == %{
               "host" => "forge.test",
               "username" => "pipemaestro-bot",
               "password" => "tok"
             }

      [job] = stage_jobs(task)
      refute Map.has_key?(job.context, "git_credential")
    end

    test "a runner that does not know the credential takes the job without it", ctx do
      linked_task(ctx, %{})
      assert_push "job:assign", pushed
      refute Map.has_key?(pushed, "git_credential")
    end

    test "renews the credential of a running job", ctx do
      task = linked_task(ctx, %{capabilities: ["git_credential"]})
      assert_push "job:assign", %{"id" => job_id}
      [job] = stage_jobs(task)
      {:ok, _} = Jobs.mark_started(ctx.runner, job.id)

      send(Process.get(:channel_pid), {:renew_credential, job_id})

      assert_push "job:credential", %{
        "job_id" => ^job_id,
        "git_credential" => %{"password" => "tok"}
      }
    end

    test "a finished job's failed setup becomes an event of the runner", ctx do
      channel = join_runner(ctx.socket, ctx.runner)
      job = job_fixture(ctx.runner, ctx.user)
      assert_push "job:assign", %{"id" => _id}
      ref = push(channel, "job:started", %{"job_id" => job.id})
      assert_reply ref, :ok

      ref =
        push(channel, "job:finished", %{
          "job_id" => job.id,
          "status" => "failed",
          "exit_code" => 1,
          "error" => "O setup falhou",
          "setup" => %{"exit_code" => 2, "command" => "mix deps.get", "output" => "erro"}
        })

      assert_reply ref, :ok

      assert [%{kind: "setup_failed", job_id: job_id}] =
               RunnerTelemetry.events(ctx.runner, ~U[2000-01-01 00:00:00Z])

      assert job_id == job.id
    end

    test "new and canceled jobs reach the runner; its reports are stored", ctx do
      channel = join_runner(ctx.socket, ctx.runner)

      job = job_fixture(ctx.runner, ctx.user)
      assert_push "job:assign", %{"id" => job_id}
      assert job_id == job.id

      ref = push(channel, "job:started", %{"job_id" => job.id})
      assert_reply ref, :ok

      ref =
        push(channel, "job:event", %{
          "job_id" => job.id,
          "seq" => 1,
          "type" => "assistant_text",
          "data" => %{"text" => "oi"}
        })

      assert_reply ref, :ok

      ref = push(channel, "job:event", %{"job_id" => job.id, "seq" => 2, "type" => "bogus"})
      assert_reply ref, :error, %{"reason" => "invalid"}

      # The account's limits are the runner's: the screens of runners reload.
      :ok = PipeMaestroWeb.RunnerStatus.subscribe(ctx.workspace.id)

      ref =
        push(channel, "job:event", %{
          "job_id" => job.id,
          "seq" => 3,
          "type" => "rate_limit",
          "data" => %{"status" => "allowed", "utilization" => %{"five_hour" => 0.5}}
        })

      assert_reply ref, :ok
      assert_receive :runners_changed

      assert %{"utilization" => %{"five_hour" => 0.5}} =
               PipeMaestro.Repo.reload!(ctx.runner).rate_limit

      # What the agent is writing goes to whoever watches the job, unstored.
      :ok = Jobs.subscribe({:job, job.id})
      push(channel, "job:delta", %{"job_id" => job.id, "text" => "Escrev"})
      assert_receive {:job_delta, ^job_id, "Escrev"}
      push(channel, "job:delta", %{"job_id" => Ecto.UUID.generate(), "text" => "alheio"})
      refute_receive {:job_delta, _, "alheio"}

      {:ok, _} = Jobs.request_cancel(Jobs.get_job!(ctx.workspace, job.id))
      assert_push "job:cancel", %{"job_id" => ^job_id}

      ref = push(channel, "job:finished", %{"job_id" => job.id, "status" => "canceled"})
      assert_reply ref, :ok

      # The CLI's telemetry may follow the end.
      ref =
        push(channel, "job:telemetry", %{
          "job_id" => job.id,
          "records" => [
            %{
              "name" => "api_request",
              "at" => "2026-11-03T12:00:00Z",
              "attrs" => %{"duration_ms" => 9}
            }
          ]
        })

      assert_reply ref, :ok
      assert [%{name: "api_request"}] = Jobs.list_telemetry(Jobs.get_job!(ctx.workspace, job.id))

      ref = push(channel, "job:telemetry", %{"job_id" => job.id, "records" => "não é lista"})
      assert_reply ref, :error, %{"reason" => "invalid"}

      ref = push(channel, "job:finished", %{"job_id" => job.id, "status" => "failed"})
      assert_reply ref, :error, %{"reason" => "finished"}

      ref = push(channel, "job:started", %{"job_id" => Ecto.UUID.generate()})
      assert_reply ref, :error, %{"reason" => "not_found"}

      ref = push(channel, "job:whatever", %{})
      assert_reply ref, :error, %{"reason" => "unknown_message"}

      assert Jobs.get_job!(ctx.workspace, job.id).status == :canceled
      assert [%{seq: 1}, %{seq: 3, type: "rate_limit"}] = Jobs.list_events(job)
    end
  end

  describe "tasks" do
    setup %{token: token, workspace: workspace, runner: runner} do
      {:ok, socket} = connect(RunnerSocket, params(token))
      user = member_fixture(workspace)
      %{socket: socket, user: user, runner: runner}
    end

    test "announces directories, updates them, and stage jobs carry their context", ctx do
      RunnerStatus.subscribe(ctx.workspace.id)
      hello = Hello.to_map(hello_fixture(%{directories: [%{"name" => "app", "git" => true}]}))

      {:ok, _reply, channel} =
        subscribe_and_join(ctx.socket, RunnerChannel, "runner:" <> ctx.runner.id, hello)

      assert_receive :runners_changed

      assert [%{"name" => "app"}] =
               Runners.get_runner!(ctx.workspace, ctx.runner.id).directories

      ref =
        push(channel, "runner:directories", %{
          "directories" => [%{"name" => "api", "git" => false}, %{"name" => "app", "git" => true}]
        })

      assert_reply ref, :ok
      assert_receive :runners_changed
      assert [_, _] = Runners.get_runner!(ctx.workspace, ctx.runner.id).directories

      ref = push(channel, "runner:directories", %{"directories" => [%{"name" => "../x"}]})
      assert_reply ref, :error, %{"reason" => "invalid"}

      pipeline = pipeline_fixture(ctx.workspace)

      {:ok, task} =
        Tasks.create_task(ctx.user, ctx.workspace, %{
          "title" => "Tarefa",
          "prompt" => "faça",
          "pipeline_id" => pipeline.id,
          "project_id" => project_on(ctx.runner, "app").id
        })

      assert_push "job:assign", %{
        "directory" => "app",
        "worktree" => %{"task_id" => task_id},
        "artifact_path" => ".control-plane/" <> _,
        "output_schema" => %{"required" => ["status", "resumo"]}
      }

      assert task_id == task.id
    end

    test "worktree removals reach the runner, again on join, and its reports are stored", ctx do
      runner = with_directories(ctx.runner, [%{"name" => "app", "git" => true}])

      {:ok, task} =
        Tasks.create_task(ctx.user, ctx.workspace, %{
          "title" => "Tarefa",
          "prompt" => "faça",
          "pipeline_id" => pipeline_fixture(ctx.workspace).id,
          "project_id" => project_on(runner, "app").id
        })

      task =
        task
        |> Ecto.Changeset.change(status: :canceled, worktree: "/w/worktrees/x")
        |> PipeMaestro.Repo.update!()

      channel = join_runner(ctx.socket, runner)
      {:ok, _task} = PipeMaestro.Tasks.remove_worktree(task)
      assert_push "worktree:remove", %{"task_id" => task_id, "directory" => "app"}
      assert task_id == task.id

      # Not confirmed: a new join sends it again.
      Process.unlink(channel.channel_pid)
      close(channel)
      channel = join_runner(ctx.socket, runner)
      assert_push "worktree:remove", %{"task_id" => ^task_id}

      ref = push(channel, "worktree:removed", %{"task_id" => task_id})
      assert_reply ref, :ok
      assert PipeMaestro.Tasks.get_task!(ctx.workspace, task_id).worktree_removed_at

      ref = push(channel, "worktree:usage", %{"count" => 1, "bytes" => 10, "free_bytes" => 99})
      assert_reply ref, :ok
      assert_receive :runners_changed
      assert %{"count" => 1} = Runners.get_runner!(ctx.workspace, runner.id).worktree_usage

      ref = push(channel, "worktree:usage", %{"count" => -1})
      assert_reply ref, :error, %{"reason" => "invalid"}
    end
  end
end
