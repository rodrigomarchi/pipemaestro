defmodule ClaudeControlPlane.Repo do
  use Ecto.Repo,
    otp_app: :claude_control_plane,
    adapter: Ecto.Adapters.Postgres
end
