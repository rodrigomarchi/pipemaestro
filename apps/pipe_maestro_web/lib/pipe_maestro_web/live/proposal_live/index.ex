defmodule PipeMaestroWeb.ProposalLive.Index do
  @moduledoc """
  The workspace's proposals (`PipeMaestro.Proposals`), newest first, with
  their status live: pipelines, tasks written from an idea or triaged from an
  issue, decisions and improvements. Filtered by kind, status, directory and
  who asked.
  """
  use PipeMaestroWeb, :live_view

  import PipeMaestroWeb.JobComponents, only: [job_status: 1]
  import PipeMaestroWeb.RunnerComponents, only: [time_ago: 2]
  import PipeMaestroWeb.ProposalComponents

  alias PipeMaestro.{Jobs, Proposals, Workspaces}

  @impl true
  def mount(_params, _session, socket) do
    workspace = socket.assigns.current_scope.workspace
    if connected?(socket), do: Jobs.subscribe({:workspace, workspace.id})

    {:ok,
     socket
     |> assign(page_title: "Propostas", filters: %{})
     |> assign(members: Workspaces.list_members(workspace))
     |> load()}
  end

  @impl true
  def handle_info({:job_updated, job}, socket) do
    if Proposals.proposal?(job), do: {:noreply, load(socket)}, else: {:noreply, socket}
  end

  @impl true
  def handle_event("filter", %{"filter" => filters}, socket),
    do: {:noreply, socket |> assign(filters: filters) |> load()}

  defp load(socket) do
    workspace = socket.assigns.current_scope.workspace

    assign(socket,
      proposals: Proposals.list(workspace, socket.assigns.filters),
      directories:
        workspace
        |> Proposals.list()
        |> Enum.map(&Proposals.input(&1)["directory"])
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> Enum.sort()
    )
  end

  defp kind_options,
    do: [
      {"Todos os tipos", ""}
      | Enum.map(Proposals.kinds(), &{Proposals.kind_module(&1).label(), &1})
    ]

  defp status_options,
    do: [
      {"Qualquer status", ""},
      {"Em andamento", "active"},
      {"Concluídas", "succeeded"},
      {"Falharam", "failed"},
      {"Canceladas", "canceled"}
    ]

  defp filtered?(filters), do: Enum.any?(filters, fn {_key, value} -> value not in [nil, ""] end)

  @impl true
  def render(assigns) do
    assigns = assign(assigns, filter_form: to_form(assigns.filters, as: "filter"))

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
          <.section_heading
            icon="hero-cpu-chip"
            title="Propostas do agente"
            description="O que o agente propôs depois de estudar um projeto: pipelines, tarefas, decisões e melhorias. Cada uma espera a sua revisão."
          />
          <.form
            for={@filter_form}
            id="proposals-filter"
            phx-change="filter"
            class="grid gap-2 sm:grid-cols-2 lg:grid-cols-4"
          >
            <.icon_field
              field={@filter_form[:kind]}
              icon="hero-funnel"
              type="select"
              label="Tipo"
              hide_label
              options={kind_options()}
              data-testid="proposals-kind"
            />
            <.icon_field
              field={@filter_form[:status]}
              icon="hero-signal"
              type="select"
              label="Status"
              hide_label
              options={status_options()}
              data-testid="proposals-status"
            />
            <.icon_field
              field={@filter_form[:directory]}
              icon="hero-folder-open"
              type="select"
              label="Diretório"
              hide_label
              options={[{"Qualquer diretório", ""} | Enum.map(@directories, &{&1, &1})]}
              data-testid="proposals-directory"
            />
            <.icon_field
              field={@filter_form[:user_id]}
              icon="hero-user"
              type="select"
              label="Quem pediu"
              hide_label
              options={[{"Qualquer pessoa", ""} | Enum.map(@members, &{&1.name, &1.id})]}
              data-testid="proposals-user"
            />
          </.form>

          <.empty
            :if={@proposals == []}
            data-testid="no-proposals"
            title={
              if filtered?(@filters),
                do: "Nenhuma proposta com esses filtros",
                else: "Nenhuma proposta ainda"
            }
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
