defmodule ClaudeControlPlaneWeb.RunnerPresence do
  @moduledoc """
  Which runners are connected right now, per workspace. A runner is tracked
  while its channel process lives; when the connection drops, it leaves.
  """
  use Phoenix.Presence,
    otp_app: :claude_control_plane_web,
    pubsub_server: ClaudeControlPlane.PubSub
end
