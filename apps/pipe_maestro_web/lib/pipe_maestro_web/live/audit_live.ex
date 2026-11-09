defmodule PipeMaestroWeb.AuditLive do
  @moduledoc """
  The workspace's audit trail (`PipeMaestro.Audit`), newest first: who
  created, decided or canceled tasks, changed pipelines and projects, and
  approved, renamed or revoked runners. Admins only.
  """
  use PipeMaestroWeb, :live_view

  import PipeMaestroWeb.RunnerComponents, only: [time_ago: 2]

  alias PipeMaestro.Audit

  # How many events a page shows, and how many more each "Carregar mais" adds.
  @page 30

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
      {:ok, socket |> assign(page_title: "Auditoria", limit: @page) |> load()}
    else
      {:ok,
       socket
       |> put_flash(:error, "Só admins do workspace veem a auditoria.")
       |> push_navigate(to: ~p"/w/#{scope.workspace.slug}")}
    end
  end

  @impl true
  def handle_event("load_more", _params, socket),
    do: {:noreply, socket |> update(:limit, &(&1 + @page)) |> load()}

  # The newest `limit` events; one more is read to know whether there are more.
  defp load(socket) do
    limit = socket.assigns.limit
    events = Audit.list_events(socket.assigns.current_scope.workspace, limit: limit + 1)

    assign(socket,
      events: Enum.take(events, limit),
      more: length(events) > limit,
      now: DateTime.utc_now()
    )
  end

  defp label(action), do: Map.get(@labels, action, action)

  # What an event is about, by the kind of its subject.
  defp subject_icon("task"), do: "hero-queue-list"
  defp subject_icon("pipeline"), do: "hero-squares-2x2"
  defp subject_icon("project"), do: "hero-folder"
  defp subject_icon("runner"), do: "hero-server-stack"
  defp subject_icon("secret"), do: "hero-key"
  defp subject_icon(_other), do: "hero-document-text"

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
      <.record_list id="audit-events" testid="audit-events" empty={@events == []}>
        <.record_card
          :for={event <- @events}
          id={"audit-event-#{event.id}"}
          testid={"audit-event-#{event.id}"}
          dense
        >
          <:leading><.record_icon icon={subject_icon(event.subject_type)} /></:leading>
          <:title>{label(event.action)}</:title>
          <:meta>
            <span class="text-gray-700 dark:text-gray-300">{event.subject_name || "—"}</span>
            <span :if={details(event.details)}>· {details(event.details)}</span>
          </:meta>
          <:aside>
            <span>
              {if event.actor_user, do: event.actor_user.name, else: "—"} · {time_ago(
                event.inserted_at,
                @now
              )}
            </span>
          </:aside>
        </.record_card>
        <:empty_state>
          <.record_empty
            testid="no-audit-events"
            icon="hero-clipboard-document-list"
            title="Nada registrado ainda"
            description="Quem criou, decidiu ou cancelou tarefas, mudou pipelines e projetos e aprovou, renomeou ou revogou runners aparece aqui."
          />
        </:empty_state>
      </.record_list>
      <.load_more more={@more} testid="audit-load-more" />
    </Layouts.app>
    """
  end
end
