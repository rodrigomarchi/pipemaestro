defmodule ClaudeControlPlane.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        ClaudeControlPlane.Repo,
        {DNSCluster,
         query: Application.get_env(:claude_control_plane, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: ClaudeControlPlane.PubSub}
      ] ++ maintenance()

    Supervisor.start_link(children, strategy: :one_for_one, name: ClaudeControlPlane.Supervisor)
  end

  # Off in tests, which call ClaudeControlPlane.Maintenance.run/2 themselves.
  defp maintenance do
    case Application.get_env(:claude_control_plane, ClaudeControlPlane.Maintenance, []) do
      false -> []
      opts -> [{ClaudeControlPlane.Maintenance, opts}]
    end
  end
end
