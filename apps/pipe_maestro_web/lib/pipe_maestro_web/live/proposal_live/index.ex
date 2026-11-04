defmodule PipeMaestroWeb.ProposalLive.Index do
  @moduledoc """
  The workspace's proposals (`PipeMaestro.Proposals`), newest first, by kind,
  with their status live: pipelines, tasks written from an idea or triaged
  from an issue, decisions and improvements.
  """
  use PipeMaestroWeb, :live_view

  import PipeMaestroWeb.JobComponents, only: [job_status: 1]
  import PipeMaestroWeb.RunnerComponents, only: [time_ago: 2]
  import PipeMaestroWeb.ProposalComponents

  alias PipeMaestro.{Jobs, Proposals}

  @impl true
  def mount(_params, _session, socket) do
    workspace = socket.assigns.current_scope.workspace
    if connected?(socket), do: Jobs.subscribe({:workspace, workspace.id})

    {:ok,
     socket
     |> assign(page_title: "Propostas", kind: "")
     |> load()}
  end

  @impl true
  def handle_info({:job_updated, job}, socket) do
    if Proposals.proposal?(job), do: {:noreply, load(socket)}, else: {:noreply, socket}
  end

  @impl true
  def handle_event("filter", %{"filter" => %{"kind" => kind}}, socket),
    do: {:noreply, socket |> assign(kind: kind) |> load()}

  defp load(socket) do
    kinds = if socket.assigns.kind in Proposals.kinds(), do: [socket.assigns.kind], else: :all

    assign(socket,
      proposals: Proposals.list_recent(socket.assigns.current_scope.workspace, kinds)
    )
  end

  defp kind_options,
    do: [
      {"Todos os tipos", ""}
      | Enum.map(Proposals.kinds(), &{Proposals.kind_module(&1).label(), &1})
    ]

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      pending_decisions={@pending_decisions}
      current_scope={@current_scope}
      workspaces={@workspaces}
      active={:proposals}
      title="Propostas"
    >
      <.card variant="outline">
        <.card_content>
          <div class="flex flex-wrap items-start justify-between gap-4">
            <.section_heading
              icon="hero-cpu-chip"
              title="Propostas do agente"
              description="O que o agente propôs depois de estudar um projeto: pipelines, tarefas, decisões e melhorias. Cada uma espera a sua revisão."
            />
            <.form
              for={to_form(%{"kind" => @kind}, as: "filter")}
              id="proposals-filter"
              phx-change="filter"
            >
              <.icon_field
                field={to_form(%{"kind" => @kind}, as: "filter")[:kind]}
                icon="hero-funnel"
                type="select"
                label="Tipo"
                hide_label
                options={kind_options()}
                data-testid="proposals-kind"
              />
            </.form>
          </div>

          <.empty
            :if={@proposals == []}
            data-testid="no-proposals"
            title="Nenhuma proposta ainda"
            description="Peça uma em Pipelines (Gerar com IA ou Melhorar com IA), em Tarefas (Escrever com IA) ou numa decisão (Sugerir com IA)."
          >
            <:icon><.icon name="hero-cpu-chip" /></:icon>
          </.empty>

          <ul
            :if={@proposals != []}
            class="divide-y divide-gray-100 dark:divide-gray-800"
            data-testid="proposals"
          >
            <li :for={job <- @proposals} class="flex flex-wrap items-center gap-3 py-3">
              <.kind_badge kind={Proposals.kind(job)} />
              <div class="min-w-0 flex-1">
                <.link
                  navigate={~p"/w/#{@current_scope.workspace.slug}/proposals/#{job.id}"}
                  class="font-medium text-gray-900 hover:underline dark:text-white"
                  data-testid={"proposal-link-#{job.id}"}
                >
                  {Proposals.title(job)}
                </.link>
                <p class="truncate text-xs text-gray-500 dark:text-gray-400">
                  {Proposals.input(job)["directory"]}
                  {if job.created_by_user, do: " · #{job.created_by_user.name}"}
                  {" · #{time_ago(job.inserted_at, DateTime.utc_now())}"}
                </p>
              </div>
              <.job_status job={job} data-testid={"proposal-status-#{job.id}"} />
            </li>
          </ul>
        </.card_content>
      </.card>
    </Layouts.app>
    """
  end
end
