defmodule PipeMaestroWeb.RunnerPresence do
  @moduledoc """
  Which runners are connected right now, per workspace. A runner is tracked
  while its channel process lives; when the connection drops, it leaves.
  """
  use Phoenix.Presence,
    otp_app: :pipe_maestro_web,
    pubsub_server: PipeMaestro.PubSub
end
