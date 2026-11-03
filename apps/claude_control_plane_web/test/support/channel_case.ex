defmodule ClaudeControlPlaneWeb.ChannelCase do
  @moduledoc """
  The test case for sockets and channels: `Phoenix.ChannelTest` against the
  endpoint, the SQL sandbox and the shared fixtures.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Phoenix.ChannelTest
      import ClaudeControlPlane.Fixtures

      @endpoint ClaudeControlPlaneWeb.Endpoint
    end
  end

  setup tags do
    ClaudeControlPlane.DataCase.setup_sandbox(tags)
    :ok
  end
end
