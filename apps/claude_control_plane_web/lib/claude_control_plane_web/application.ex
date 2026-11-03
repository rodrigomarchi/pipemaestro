defmodule ClaudeControlPlaneWeb.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      ClaudeControlPlaneWeb.Telemetry,
      # Start a worker by calling: ClaudeControlPlaneWeb.Worker.start_link(arg)
      # {ClaudeControlPlaneWeb.Worker, arg},
      # Start to serve requests, typically the last entry
      ClaudeControlPlaneWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: ClaudeControlPlaneWeb.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ClaudeControlPlaneWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
