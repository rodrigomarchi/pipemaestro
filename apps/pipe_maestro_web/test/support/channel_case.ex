defmodule PipeMaestroWeb.ChannelCase do
  @moduledoc """
  The test case for sockets and channels: `Phoenix.ChannelTest` against the
  endpoint, the SQL sandbox and the shared fixtures.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Phoenix.ChannelTest
      import PipeMaestro.Fixtures

      @endpoint PipeMaestroWeb.Endpoint
    end
  end

  setup tags do
    PipeMaestro.DataCase.setup_sandbox(tags)
    :ok
  end
end
