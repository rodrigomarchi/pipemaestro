defmodule PipeMaestro.Workspaces.PlanTest do
  use ExUnit.Case, async: true

  alias PipeMaestro.Workspaces.Plan

  test "the Free beta plan's limits" do
    assert Plan.free_beta() == %{
             workspaces_per_owner: 3,
             max_running_tasks: 2,
             job_files_quota_mib: 500,
             job_files_retention_days: 14,
             agent_events_retention_days: 14,
             runner_log_retention_days: 7
           }
  end
end
