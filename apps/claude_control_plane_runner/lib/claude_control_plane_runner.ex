defmodule ClaudeControlPlaneRunner do
  @moduledoc """
  The runner: a daemon installed on the customer's infrastructure that opens an
  outbound connection to the control plane, pulls stage jobs and runs each one
  in an ephemeral container.
  """

  @doc "The protocol version this runner announces to the control plane."
  @spec protocol_version() :: pos_integer()
  def protocol_version, do: ClaudeControlPlaneProtocol.version()
end
