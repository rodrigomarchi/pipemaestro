defmodule PipeMaestro.Runners.RateLimitTest do
  use PipeMaestro.DataCase, async: true

  import PipeMaestro.Fixtures

  alias PipeMaestro.{Jobs, Repo, Runners}
  alias PipeMaestro.Runners.Runner

  setup do
    workspace = workspace_fixture()
    user = member_fixture(workspace)
    {runner, _token} = runner_fixture(workspace, user)
    %{runner: runner, user: user}
  end

  test "a run's rate limit event is kept on its runner", ctx do
    job = job_fixture(ctx.runner, ctx.user)
    {:ok, _} = Jobs.mark_started(ctx.runner, job.id)

    {:ok, _} =
      Jobs.append_event(ctx.runner, job.id, %{
        "seq" => 1,
        "type" => "rate_limit",
        "data" => %{
          "status" => "allowed_warning",
          "window" => "five_hour",
          "utilization" => %{"five_hour" => 0.85, "seven_day" => 0.4},
          "resets_at" => 4_102_444_800
        }
      })

    runner = Repo.reload!(ctx.runner)

    assert %{
             "status" => "allowed_warning",
             "utilization" => %{"five_hour" => 0.85},
             "resets_at" => 4_102_444_800,
             "at" => _
           } = runner.rate_limit

    assert Runners.near_limit?(runner)
  end

  describe "near_limit?/2" do
    test "a window at 80% or more, or a status other than allowed" do
      refute Runners.near_limit?(%Runner{rate_limit: nil})
      refute Runners.near_limit?(seen("allowed", %{"five_hour" => 0.5}))
      assert Runners.near_limit?(seen("allowed", %{"five_hour" => 0.8}))
      assert Runners.near_limit?(seen("rejected", %{}))
    end

    test "not once the limit reset" do
      past = DateTime.utc_now() |> DateTime.add(-60) |> DateTime.to_unix()
      refute Runners.near_limit?(seen("rejected", %{"five_hour" => 1.0}, past))

      future = DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601()
      assert Runners.near_limit?(seen("rejected", %{}, future))
    end
  end

  test "resets_at/1 reads Unix seconds and ISO 8601" do
    assert Runners.resets_at(0) == ~U[1970-01-01 00:00:00Z]
    assert Runners.resets_at(1.4) == ~U[1970-01-01 00:00:01Z]
    assert Runners.resets_at("2026-11-04T10:00:00Z") == ~U[2026-11-04 10:00:00Z]
    assert Runners.resets_at("amanhã") == nil
    assert Runners.resets_at(nil) == nil
  end

  defp seen(status, utilization, resets_at \\ nil),
    do: %Runner{
      rate_limit: %{"status" => status, "utilization" => utilization, "resets_at" => resets_at}
    }
end
