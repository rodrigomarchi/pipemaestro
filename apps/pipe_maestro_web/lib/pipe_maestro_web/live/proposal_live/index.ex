defmodule PipeMaestroWeb.ProposalLive.Index do
  @moduledoc """
  The workspace's proposals (`PipeMaestro.Proposals`), newest first, with
  their status live: pipelines, tasks written from an idea or triaged from an
  issue, decisions and improvements, each with its project. Filtered by
  kind, status, project and who asked.
  """
  use PipeMaestroWeb, :live_view

  import PipeMaestroWeb.JobComponents, only: [job_status: 1, job_tone: 1]
  import PipeMaestroWeb.RunnerComponents, only: [time_ago: 2]
  import PipeMaestroWeb.ProposalComponents

  alias PipeMaestro.{Jobs, Projects, Proposals, Workspaces}

  # How many proposals a page shows, and how many more each "Carregar mais" adds.
  @page 30

  @impl true
  def mount(_params, _session, socket) do
    workspace = socket.assigns.current_scope.workspace
    if connected?(socket), do: Jobs.subscribe({:workspace, workspace.id})

    {:ok,
     socket
     |> assign(page_title: "Propostas", filters: %{}, limit: @page)
     |> assign(members: Workspaces.list_members(workspace))
     |> load()}
  end

  @impl true
  def handle_info({:job_updated, job}, socket) do
    if Proposals.proposal?(job), do: {:noreply, load(socket)}, else: {:noreply, socket}
  end

  @impl true
  def handle_event("filter", %{"filter" => filters}, socket),
    do: {:noreply, socket |> assign(filters: filters, limit: @page) |> load()}

  def handle_event("load_more", _params, socket),
    do: {:noreply, socket |> update(:limit, &(&1 + @page)) |> load()}

  # The newest `limit` proposals; one more is read to know whether there are more.
  defp load(socket) do
    workspace = socket.assigns.current_scope.workspace
    limit = socket.assigns.limit
    proposals = Proposals.list(workspace, socket.assigns.filters, limit + 1)

    assign(socket,
      proposals: Enum.take(proposals, limit),
      more: length(proposals) > limit,
      projects: Projects.list_projects(workspace)
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
      notification_center={@notification_center}
      current_scope={@current_scope}
      workspaces={@workspaces}
      active={:proposals}
      title="Propostas"
    >
      <.filter_bar>
        <.form
          for={@filter_form}
          id="proposals-filter"
          phx-change="filter"
          class="grid w-full gap-2 sm:grid-cols-2 lg:grid-cols-4"
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
            field={@filter_form[:project_id]}
            icon="hero-folder-open"
            type="select"
            label="Projeto"
            hide_label
            options={[{"Qualquer projeto", ""} | Enum.map(@projects, &{&1.name, &1.id})]}
            data-testid="proposals-project"
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
      </.filter_bar>

      <.record_list id="proposals" testid="proposals" empty={@proposals == []}>
        <.record_card
          :for={job <- @proposals}
          id={"proposal-row-#{job.id}"}
          testid={"proposal-row-#{job.id}"}
          navigate={~p"/w/#{@current_scope.workspace.slug}/proposals/#{job.id}"}
          link_testid={"proposal-link-#{job.id}"}
          tone={job_tone(job)}
        >
          <:leading>
            <.record_icon icon={Proposals.kind_module(Proposals.kind(job)).icon()} color="primary" />
          </:leading>
          <:title>{Proposals.title(job)}</:title>
          <:badge><.job_status job={job} data-testid={"proposal-status-#{job.id}"} /></:badge>
          <:meta>
            <.kind_badge kind={Proposals.kind(job)} />
            <.record_fact icon="hero-folder" title="Projeto" testid={"proposal-project-#{job.id}"}>
              {if job.project, do: job.project.name, else: Proposals.input(job)["directory"]}
            </.record_fact>
            <.record_fact :if={job.created_by_user} icon="hero-user" title="Quem pediu">
              {job.created_by_user.name}
            </.record_fact>
          </:meta>
          <:aside>
            <.record_metric icon="hero-calendar" title="Pedida">
              {time_ago(job.inserted_at, DateTime.utc_now())}
            </.record_metric>
          </:aside>
        </.record_card>
        <:empty_state>
          <.record_empty
            testid="no-proposals"
            icon="hero-cpu-chip"
            title={
              if filtered?(@filters),
                do: "Nenhuma proposta com esses filtros",
                else: "Nenhuma proposta ainda"
            }
            description="O agente propõe pipelines, tarefas, decisões e melhorias depois de estudar um projeto. Peça uma em Pipelines (Gerar com IA ou Melhorar com IA), em Tarefas (Escrever com IA) ou numa decisão (Sugerir com IA)."
          />
        </:empty_state>
      </.record_list>
      <.load_more more={@more} testid="proposals-load-more" />
    </Layouts.app>
    """
  end
end
