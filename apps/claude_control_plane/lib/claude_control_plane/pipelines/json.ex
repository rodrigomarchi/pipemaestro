defmodule ClaudeControlPlane.Pipelines.Json do
  @moduledoc """
  JSON as the pipeline forms show it to a person: indented, one key per line
  (the MCP servers, the agents, a stage's output schema).
  """

  @doc "`value` as indented JSON."
  @spec pretty(term()) :: String.t()
  def pretty(value) do
    # Encoded first (nil becomes null), then read back as plain JSON values,
    # which OTP's formatter indents.
    value
    |> JSON.encode!()
    |> :json.decode()
    |> :json.format()
    |> IO.iodata_to_binary()
    |> String.trim_trailing()
  end
end
