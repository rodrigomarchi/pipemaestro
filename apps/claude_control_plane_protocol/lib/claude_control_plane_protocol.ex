defmodule ClaudeControlPlaneProtocol do
  @moduledoc """
  The contract between a runner and the control plane.

  Both sides depend on this app and on nothing of each other's. The contract is
  public and versioned: a runner announces the version it speaks, and the
  control plane keeps serving older versions for a defined compatibility window.
  """

  @version 1

  @doc "The protocol version this build speaks."
  @spec version() :: pos_integer()
  def version, do: @version
end
