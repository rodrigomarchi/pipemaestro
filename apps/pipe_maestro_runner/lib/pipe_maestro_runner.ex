defmodule PipeMaestroRunner do
  @moduledoc """
  The runner: a daemon installed on the customer's infrastructure that opens an
  outbound connection to the control plane and, later, runs pipeline stages in
  ephemeral containers.

  - `PipeMaestroRunner.DeviceLogin` signs the runner in (device flow);
  - `PipeMaestroRunner.Config` keeps its credentials on disk;
  - `PipeMaestroRunner.Connection` keeps it connected;
  - `PipeMaestroRunner.Host` describes the machine.

  The `runner.*` Mix tasks are the command line (see the root Makefile).
  """
end
