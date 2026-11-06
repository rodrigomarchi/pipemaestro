defmodule PipeMaestro.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        PipeMaestro.Repo,
        {DNSCluster, query: Application.get_env(:pipe_maestro, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: PipeMaestro.PubSub},
        # Integrations' deliveries, processed outside the webhook's request.
        {Task.Supervisor, name: PipeMaestro.Integrations.TaskSupervisor}
      ] ++ maintenance() ++ reconciler()

    Supervisor.start_link(children, strategy: :one_for_one, name: PipeMaestro.Supervisor)
  end

  # Off in tests, which call PipeMaestro.Integrations.Reconciler.run/2 themselves.
  defp reconciler do
    case Application.get_env(:pipe_maestro, PipeMaestro.Integrations.Reconciler, []) do
      false -> []
      opts -> [{PipeMaestro.Integrations.Reconciler, opts}]
    end
  end

  # Off in tests, which call PipeMaestro.Maintenance.run/2 themselves.
  defp maintenance do
    case Application.get_env(:pipe_maestro, PipeMaestro.Maintenance, []) do
      false -> []
      opts -> [{PipeMaestro.Maintenance, opts}]
    end
  end
end
