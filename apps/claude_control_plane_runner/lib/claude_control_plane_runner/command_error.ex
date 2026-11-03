defmodule ClaudeControlPlaneRunner.CommandError do
  @moduledoc "A runner command stopped; the message says why and what to do."
  defexception [:message]
end
