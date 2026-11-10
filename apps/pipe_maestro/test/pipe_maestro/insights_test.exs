defmodule PipeMaestro.InsightsTest do
  use PipeMaestro.DataCase, async: true

  import PipeMaestro.Fixtures

  alias PipeMaestro.{Insights, Jobs, Maintenance, Repo, Workspaces}

  setup do
    workspace = workspace_fixture()
    user = member_fixture(workspace)
    {runner, _token} = runner_fixture(workspace, user)
    %{workspace: workspace, user: user, runner: runner}
  end

  # A job that read a file, ran a command that failed, had a call refused,
  # retried the API once and was compacted.
  defp audited_job(ctx) do
    job = job_fixture(ctx.runner, ctx.user)
    {:ok, _} = Jobs.mark_started(ctx.runner, job.id)

    events = [
      {"tool_use", %{"id" => "t1", "name" => "Read"}},
      {"tool_result", %{"tool_use_id" => "t1", "is_error" => false}},
      {"tool_use", %{"id" => "t2", "name" => "Bash", "parent_tool_use_id" => "task1"}},
      {"tool_result", %{"tool_use_id" => "t2", "is_error" => true}},
      {"tool_use", %{"id" => "t3", "name" => "Bash"}},
      {"tool_result",
       %{"tool_use_id" => "t3", "is_error" => true, "decision" => %{"decision" => "reject"}}},
      {"permission_denied", %{"tool_name" => "Write", "tool_use_id" => "t4"}},
      {"api_retry", %{"attempt" => 1, "error" => "overloaded"}},
      {"compact", %{"trigger" => "auto"}},
      {"thinking", %{"duration_ms" => 400}},
      {"thinking", %{"duration_ms" => 600}},
      {"rate_limit", %{"status" => "allowed", "utilization" => %{"five_hour" => 0.2}}}
    ]

    for {{type, data}, seq} <- Enum.with_index(events, 1) do
      {:ok, _} =
        Jobs.append_event(ctx.runner, job.id, %{"seq" => seq, "type" => type, "data" => data})
    end

    {:ok, _} =
      Jobs.record_telemetry(ctx.runner, job.id, [
        tel("api_request", 0, %{"duration_ms" => 1000, "ttft_ms" => 400}),
        tel("api_request", 1, %{"duration_ms" => 2000, "ttft_ms" => 600}),
        tel("api_request", 2, %{"duration_ms" => 3000, "ttft_ms" => 800}),
        tel("api_error", 3, %{"error" => "overloaded", "status_code" => 529, "attempt" => 1}),
        tel("tool_result", 4, %{
          "tool_name" => "Read",
          "tool_use_id" => "t1",
          "duration_ms" => 5,
          "success" => true
        }),
        tel("tool_result", 5, %{
          "tool_name" => "Bash",
          "tool_use_id" => "t2",
          "duration_ms" => 700,
          "success" => false
        })
      ])

    {:ok, job} =
      Jobs.finish_job(ctx.runner, job.id, %{
        "status" => "succeeded",
        "cost_usd" => 0.01,
        "ttft_ms" => 500,
        "duration_api_ms" => 6000,
        "wall_ms" => 9000,
        "usage" => %{
          "fresh_input" => 100,
          "cache_read" => 800,
          "cache_creation" => 100,
          "output" => 50
        },
        "model_usage" => %{
          "claude-haiku-5-5" => %{"fresh_input" => 100, "output" => 50, "cost_usd" => 0.004},
          "claude-sonnet-5-5" => %{"fresh_input" => 0, "output" => 0, "cost_usd" => 0.006}
        },
        "permission_denials" => [%{"tool_name" => "Write"}]
      })

    job
  end

  defp tel(name, second, attrs) do
    at = DateTime.add(~U[2026-11-03 12:00:00Z], second) |> DateTime.to_iso8601()
    %{"name" => name, "at" => at, "attrs" => attrs}
  end

  describe "job/1" do
    test "consolidates how the agent worked in one run", ctx do
      insights = ctx |> audited_job() |> Insights.job()

      assert [bash, read] = insights.tools
      assert %{name: "Bash", calls: 2, errors: 2, denied: 1, total_ms: 700} = bash
      assert %{name: "Read", calls: 1, errors: 0, denied: 0, total_ms: 5, avg_ms: 5} = read

      assert [%{"tool_name" => "Write"}] = insights.denials

      assert %{requests: 3, p50_ms: 2000, p95_ms: 3000, max_ms: 3000, avg_ttft_ms: 600} =
               insights.api

      assert insights.api.errors == [%{error: "overloaded", status: 529, attempt: 1}]
      assert insights.api.retries == 1

      assert insights.cache_hit == 0.8

      assert [%{model: "claude-sonnet-5-5", cost_usd: 0.006}, %{model: "claude-haiku-5-5"}] =
               insights.models

      assert insights.compactions == 1
      assert insights.subagent_calls == 1
      assert insights.thinking == %{count: 2, total_ms: 1000}

      assert insights.rate_limit == %{
               "status" => "allowed",
               "utilization" => %{"five_hour" => 0.2}
             }
    end

    test "a job without audit data gives empty insights", ctx do
      insights = Insights.job(job_fixture(ctx.runner, ctx.user))
      assert insights.tools == []
      assert insights.api.requests == 0
      assert insights.cache_hit == nil
    end
  end

  describe "workspace/2" do
    test "the agent's work over a period", ctx do
      audited_job(ctx)
      other = workspace_fixture()
      other_user = member_fixture(other)
      {other_runner, _} = runner_fixture(other, other_user)
      audited_job(%{ctx | workspace: other, user: other_user, runner: other_runner})

      insights = Insights.workspace(ctx.workspace, 7)

      assert %{jobs: 1, fresh_input: 100, cache_read: 800, cache_creation: 100, output: 50} =
               insights.tokens

      assert insights.cache_hit == 0.8

      assert [%{model: "claude-sonnet-5-5"}, %{model: "claude-haiku-5-5", cost_usd: 0.004}] =
               insights.models

      assert [%{name: "Bash", calls: 2, errors: 2, denied: 1, avg_ms: 700}, %{name: "Read"}] =
               insights.tools

      assert %{requests: 3, errors: 1, retries: 1, avg_ms: 2000, avg_ttft_ms: 600} = insights.api
      assert insights.denials == 1
      assert insights.compactions == 1
    end

    test "a run past the retention of its events still counts", ctx do
      job = audited_job(ctx)
      delete_after_retention(ctx)
      age(job, 60)

      Maintenance.run(DateTime.utc_now())
      assert Jobs.list_events(job) == []

      assert Insights.workspace(ctx.workspace, 30).tokens.jobs == 0
      insights = Insights.workspace(ctx.workspace, 90)
      assert insights.tokens.jobs == 1
      assert [%{name: "Bash", calls: 2}, %{name: "Read", calls: 1}] = insights.tools
      assert %{requests: 3, errors: 1, retries: 1} = insights.api
    end

    test "only a pipeline's runs", ctx do
      audited_job(ctx)
      assert Insights.workspace(ctx.workspace, 7, %{"pipeline" => ""}).tokens.jobs == 1
      assert Insights.workspace(ctx.workspace, 7, %{"pipeline" => "nenhum"}).tokens.jobs == 0
    end
  end

  describe "the kept summary" do
    test "is written when the run ends and outlives its events", ctx do
      job = audited_job(ctx)
      delete_after_retention(ctx)
      assert %{"api" => %{"requests" => 3}, "compactions" => 1} = job.insights
      before = Insights.job(job)

      age(job, 40)
      Maintenance.run(DateTime.utc_now())

      assert Jobs.list_events(job) == []
      assert job_telemetry(job) == []
      assert Insights.job(Repo.reload!(job)) == before
    end

    test "outlives the events' content, and is not written again from what is left", ctx do
      job = audited_job(ctx)
      before = Insights.job(job)
      kept = Repo.reload!(job).insights

      age(job, 40)
      Maintenance.run(DateTime.utc_now())

      job = Repo.reload!(job)
      assert %DateTime{} = Map.get(job, :events_pruned_at)
      assert length(Jobs.list_events(job)) == 12
      assert Insights.job(job) == before

      Insights.store_summary(job)
      assert Repo.reload!(job).insights == kept
    end

    test "takes in records that arrive after the run ended", ctx do
      job = audited_job(ctx)

      {:ok, 1} =
        Jobs.record_telemetry(ctx.runner, job.id, [
          tel("api_request", 9, %{"duration_ms" => 4000})
        ])

      assert Repo.reload!(job).insights["api"]["requests"] == 4
    end

    test "a run without a summary gets one from the housekeeping", ctx do
      job = audited_job(ctx)
      job |> Ecto.Changeset.change(insights: nil) |> Repo.update!()

      assert %{summarized: 1} = Maintenance.run(DateTime.utc_now())
      assert Repo.reload!(job).insights["api"]["requests"] == 3
    end
  end

  describe "timing and extras" do
    test "where the time went and what else the run reported", ctx do
      job = job_fixture(ctx.runner, ctx.user)
      {:ok, _} = Jobs.mark_started(ctx.runner, job.id)

      {:ok, _} =
        Jobs.append_event(ctx.runner, job.id, %{
          "seq" => 1,
          "type" => "tool_use",
          "data" => %{"id" => "t1", "name" => "Read"}
        })

      {:ok, _} =
        Jobs.record_telemetry(ctx.runner, job.id, [
          tel("tool_result", 0, %{
            "tool_name" => "Read",
            "tool_use_id" => "t1",
            "duration_ms" => 30
          }),
          tel("api_request", 1, %{"query_source" => "sdk", "cost_usd" => 0.25}),
          tel("api_request", 2, %{"query_source" => "sdk", "cost_usd" => 0.5}),
          tel("api_request", 3, %{"query_source" => "compact", "cost_usd" => 0.25}),
          tel("api_refusal", 4, %{"error" => "refused"}),
          tel("mcp_server_connection", 5, %{
            "status" => "connected",
            "transport_type" => "http",
            "server_scope" => "user",
            "duration_ms" => 200
          }),
          tel("mcp_server_connection", 6, %{
            "status" => "failed",
            "transport_type" => "stdio",
            "server_scope" => "project"
          }),
          tel("tool_decision", 7, %{"decision" => "accept", "source" => "config"}),
          tel("tool_decision", 8, %{"decision" => "accept", "source" => "config"}),
          tel("tool_decision", 9, %{"decision" => "reject", "source" => "hook"}),
          tel("subagent_completed", 10, %{"agent_type" => "Explore"}),
          tel("metric:active_time", 11, %{"value" => 42})
        ])

      {:ok, job} =
        Jobs.finish_job(ctx.runner, job.id, %{
          "status" => "succeeded",
          "duration_api_ms" => 5000,
          "wall_ms" => 9000,
          "setup" => %{"duration_ms" => 1500},
          "gates" => [%{"duration_ms" => 700}, %{"duration_ms" => 300}, %{}]
        })

      insights = Insights.job(job)

      assert %{setup_ms: 1500, gates_ms: 1000, api_ms: 5000, tools_ms: 30, wall_ms: 9000} =
               insights.timing

      assert is_integer(insights.timing.queue_ms)
      assert insights.api.refusals == 1

      extras = insights.extras
      assert extras.active_seconds == 42
      assert extras.mcp_failures == 1

      assert [%{status: "connected", transport: "http", scope: "user", duration_ms: 200}, _] =
               extras.mcp

      assert [
               %{source: "config", decision: "accept", count: 2},
               %{source: "hook", decision: "reject", count: 1}
             ] = extras.decisions

      assert extras.subagents == [%{agent_type: "Explore", count: 1}]

      assert [%{source: "sdk", requests: 2, cost_usd: 0.75}, %{source: "compact", requests: 1}] =
               extras.by_query_source

      workspace = Insights.workspace(ctx.workspace, 7)
      assert workspace.active_seconds == 42
      assert workspace.mcp_failures == 1
      assert workspace.api.refusals == 1
    end

    test "a run without setup, gates or tools leaves those out", ctx do
      job = job_fixture(ctx.runner, ctx.user)
      {:ok, _} = Jobs.mark_started(ctx.runner, job.id)
      {:ok, job} = Jobs.finish_job(ctx.runner, job.id, %{"status" => "failed"})

      assert %{setup_ms: nil, gates_ms: nil, tools_ms: nil, api_ms: nil} =
               Insights.job(job).timing
    end
  end

  describe "live/1" do
    test "what a running job spent so far", ctx do
      job = job_fixture(ctx.runner, ctx.user)
      {:ok, _} = Jobs.mark_started(ctx.runner, job.id)

      {:ok, _} =
        Jobs.append_event(ctx.runner, job.id, %{
          "seq" => 1,
          "type" => "tool_use",
          "data" => %{"id" => "t1", "name" => "Read"}
        })

      {:ok, _} =
        Jobs.record_telemetry(ctx.runner, job.id, [
          tel("api_request", 0, %{
            "cost_usd" => 0.5,
            "input_tokens" => 10,
            "output_tokens" => 20,
            "cache_read_tokens" => 30
          }),
          tel("api_request", 1, %{"cost_usd" => 0.25, "output_tokens" => 5})
        ])

      assert Insights.live(job) == %{requests: 2, cost_usd: 0.75, tokens: 65, tool_calls: 1}
    end

    test "nothing yet", ctx do
      assert Insights.live(job_fixture(ctx.runner, ctx.user)) ==
               %{requests: 0, cost_usd: 0, tokens: 0, tool_calls: 0}
    end
  end

  defp delete_after_retention(ctx) do
    {:ok, _} =
      Workspaces.update_workspace(ctx.workspace, %{agent_events_after_retention: "delete"})
  end

  defp age(job, days) do
    job
    |> Ecto.Changeset.change(finished_at: DateTime.add(DateTime.utc_now(:second), -days, :day))
    |> Repo.update!()
  end
end
