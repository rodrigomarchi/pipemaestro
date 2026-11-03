defmodule ClaudeControlPlaneRunner do
  @moduledoc """
  The runner: a daemon installed on the customer's infrastructure that opens an
  outbound connection to the control plane and, later, runs pipeline stages in
  ephemeral containers.

  - `ClaudeControlPlaneRunner.DeviceLogin` signs the runner in (device flow);
  - `ClaudeControlPlaneRunner.Config` keeps its credentials on disk;
  - `ClaudeControlPlaneRunner.Connection` keeps it connected;
  - `ClaudeControlPlaneRunner.Host` describes the machine.

  The `runner.*` Mix tasks are the command line (see the root Makefile).
  """
end
