defmodule ClaudeControlPlane.InsightsTest do
  use ClaudeControlPlane.DataCase, async: true

  import ClaudeControlPlane.Fixtures

  alias ClaudeControlPlane.{Insights, Jobs}

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

      assert [%{name: "Bash", calls: 1, errors: 1, avg_ms: 700}, %{name: "Read"}] = insights.tools
      assert %{requests: 3, errors: 1, retries: 1, avg_ms: 2000, avg_ttft_ms: 600} = insights.api
      assert insights.denials == 1
      assert insights.compactions == 1
    end
  end
end
