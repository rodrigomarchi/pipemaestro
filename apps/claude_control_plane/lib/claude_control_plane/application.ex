defmodule ClaudeControlPlane.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      ClaudeControlPlane.Repo,
      {DNSCluster,
       query: Application.get_env(:claude_control_plane, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: ClaudeControlPlane.PubSub}
      # Start a worker by calling: ClaudeControlPlane.Worker.start_link(arg)
      # {ClaudeControlPlane.Worker, arg}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: ClaudeControlPlane.Supervisor)
  end
end
