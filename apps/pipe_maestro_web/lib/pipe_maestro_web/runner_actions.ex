defmodule PipeMaestroWeb.RunnerActions do
  @moduledoc """
  What a workspace admin does to a runner from any screen: revoking it
  invalidates its token, records it in the audit log, drops its connection
  and refreshes every screen that lists the workspace's runners.
  """

  alias PipeMaestro.{Audit, Runners}
  alias PipeMaestro.Runners.Runner
  alias PipeMaestroWeb.RunnerStatus

  @doc "Revokes `runner` on behalf of the scope's user."
  @spec revoke(map(), Runner.t()) :: Runner.t()
  def revoke(%{workspace: workspace, user: user}, %Runner{} = runner) do
    {:ok, runner} = Runners.revoke_runner(runner)
    Audit.record(workspace, user, "runner.revoked", runner)
    RunnerStatus.disconnect(runner)
    RunnerStatus.notify_changed(runner.workspace_id)
    runner
  end
end
