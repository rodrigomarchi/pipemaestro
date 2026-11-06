defmodule PipeMaestro.Runners.Presence do
  @moduledoc """
  Who is connected right now. The runners' channel lives in the web app, so it
  is the web app that knows (`PipeMaestroWeb.RunnerStatus`), and it says so
  through `config :pipe_maestro, PipeMaestro.Runners, presence: module`. Work
  that runs outside a request, such as an integration's deliveries, asks
  through `PipeMaestro.Runners.online_ids/2`.
  """

  @doc "Ids of the workspace's runners connected right now."
  @callback online_ids(workspace_id :: Ecto.UUID.t()) :: MapSet.t(String.t())
end
