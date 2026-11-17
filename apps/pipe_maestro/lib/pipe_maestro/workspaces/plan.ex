defmodule PipeMaestro.Workspaces.Plan do
  @moduledoc """
  The plans a workspace can be on (ADR 0058). `:custom` is a workspace an
  operator set up, with whatever limits they chose. `:free_beta` is one created
  through self-serve sign-up: it gets the limits below, and its owner can create
  only so many of them. The pricing page shows these same numbers.
  """

  @type limits :: %{
          workspaces_per_owner: pos_integer(),
          max_running_tasks: pos_integer(),
          job_files_quota_mib: pos_integer(),
          job_files_retention_days: pos_integer(),
          agent_events_retention_days: pos_integer(),
          runner_log_retention_days: non_neg_integer()
        }

  @doc "The limits of the Free plan while in beta."
  @spec free_beta() :: limits()
  def free_beta do
    %{
      workspaces_per_owner: 3,
      max_running_tasks: 2,
      job_files_quota_mib: 500,
      job_files_retention_days: 14,
      agent_events_retention_days: 14,
      runner_log_retention_days: 7
    }
  end
end
