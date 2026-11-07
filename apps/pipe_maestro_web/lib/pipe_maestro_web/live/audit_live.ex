defmodule PipeMaestroWeb.AuditLive do
  @moduledoc """
  The workspace's audit trail (`PipeMaestro.Audit`), newest first: who
  created, decided or canceled tasks, changed pipelines and projects, and
  approved, renamed or revoked runners. Admins only.
  """
  use PipeMaestroWeb, :live_view

  import PipeMaestroWeb.RunnerComponents, only: [time_ago: 2]

  alias PipeMaestro.Audit

  @labels %{
    "task.created" => "Tarefa criada",
    "task.auto_created" => "Tarefa criada automaticamente da proposta",
    "task.decided" => "Decisão tomada",
    "task.canceled" => "Tarefa cancelada",
    "pipeline.saved" => "Pipeline salvo",
    "pipeline.imported" => "Pipeline importado",
    "pipeline.deleted" => "Pipeline removido",
    "project.saved" => "Projeto salvo",
    "project.deleted" => "Projeto removido",
    "runner.approved" => "Runner aprovado",
    "runner.renamed" => "Runner renomeado",
    "runner.revoked" => "Runner revogado",
    "secret.saved" => "Segredo salvo",
    "secret.deleted" => "Segredo removido"
  }

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if can?(scope, :manage_runners) do
      {:ok,
       assign(socket,
         page_title: "Auditoria",
         events: Audit.list_events(scope.workspace),
         now: DateTime.utc_now()
       )}
    else
      {:ok,
       socket
       |> put_flash(:error, "Só admins do workspace veem a auditoria.")
       |> push_navigate(to: ~p"/w/#{scope.workspace.slug}")}
    end
  end

  defp label(action), do: Map.get(@labels, action, action)

  defp details(%{"version" => version}), do: "v#{version}"

  defp details(%{"action" => action, "choice" => choice}) when is_binary(choice),
    do: "#{action}: #{choice}"

  defp details(%{"action" => action}), do: action
  defp details(%{"pipeline" => pipeline}), do: pipeline
  defp details(_details), do: nil

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      pending_decisions={@pending_decisions}
      notification_center={@notification_center}
      current_scope={@current_scope}
      workspaces={@workspaces}
      active={:audit}
      title="Auditoria"
    >
      <.card variant="outline">
        <.card_header
          title="Quem fez o quê"
          description="Tarefas, decisões, pipelines, projetos e runners deste workspace."
        />
        <.card_content>
          <p :if={@events == []} class="text-sm text-gray-500 dark:text-gray-400">
            Nada registrado ainda.
          </p>
          <ol class="divide-y divide-gray-100 text-sm dark:divide-gray-800" data-testid="audit-events">
            <li :for={event <- @events} class="flex flex-wrap items-center justify-between gap-2 py-2">
              <span class="min-w-0">
                <span class="font-medium text-gray-900 dark:text-white">{label(event.action)}</span>
                <span class="text-gray-700 dark:text-gray-300">· {event.subject_name || "—"}</span>
                <span :if={details(event.details)} class="text-gray-500 dark:text-gray-400">
                  ({details(event.details)})
                </span>
              </span>
              <span class="shrink-0 text-xs text-gray-500 dark:text-gray-400">
                {if event.actor_user, do: event.actor_user.name, else: "—"} · {time_ago(
                  event.inserted_at,
                  @now
                )}
              </span>
            </li>
          </ol>
        </.card_content>
      </.card>
    </Layouts.app>
    """
  end
end
