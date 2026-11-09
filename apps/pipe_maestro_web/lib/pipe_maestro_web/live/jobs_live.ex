defmodule PipeMaestroWeb.JobsLive do
  @moduledoc """
  The workspace's jobs, newest first and updated live, and the form that sends
  a new prompt to a project (`?project_id=<id>` opens it with the project):
  it runs on the project's runner, in a disposable worktree of its directory,
  and waits for the runner while it is offline.
  """
  use PipeMaestroWeb, :live_view

  # How many jobs a page shows, and how many more each "Carregar mais" adds.
  @page 30

  import PipeMaestroWeb.JobComponents
  import PipeMaestroWeb.RunnerComponents, only: [time_ago: 2]

  alias Phoenix.Socket.Broadcast
  alias PipeMaestro.{Jobs, Projects}
  alias PipeMaestroWeb.{ProjectChoice, RunnerStatus}

  @impl true
  def mount(_params, _session, socket) do
    workspace = socket.assigns.current_scope.workspace

    if connected?(socket) do
      Jobs.subscribe({:workspace, workspace.id})
      RunnerStatus.subscribe(workspace.id)
    end

    {:ok,
     socket
     |> assign(page_title: "Execuções", creating: false, form: nil, params: %{})
     |> assign(limit: @page)
     |> load_jobs()
     |> load_projects()}
  end

  @impl true
  def handle_params(%{"project_id" => id}, _uri, socket),
    do: {:noreply, open_form(socket, %{"project_id" => id})}

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  defp open_form(socket, params),
    do:
      assign(socket,
        creating: true,
        params: params,
        form: to_form(Jobs.change_job(params), as: "job")
      )

  @impl true
  def handle_info({:job_updated, _job}, socket), do: {:noreply, load_jobs(socket)}

  def handle_info(%Broadcast{event: "presence_diff"}, socket),
    do: {:noreply, load_projects(socket)}

  def handle_info(:runners_changed, socket), do: {:noreply, load_projects(socket)}

  @impl true
  def handle_event("open_new", _params, socket), do: {:noreply, open_form(socket, %{})}

  def handle_event("load_more", _params, socket),
    do: {:noreply, socket |> update(:limit, &(&1 + @page)) |> load_jobs()}

  def handle_event("validate", %{"job" => params}, socket),
    do:
      {:noreply,
       assign(socket, params: params, form: to_form(Jobs.change_job(params), as: "job"))}

  def handle_event("close_new", _params, socket),
    do: {:noreply, assign(socket, creating: false, form: nil)}

  def handle_event("create", %{"job" => params}, socket) do
    %{user: user, workspace: workspace} = socket.assigns.current_scope

    case Jobs.create_job(user, workspace, params) do
      {:ok, job} ->
        {:noreply,
         socket
         |> put_flash(:info, "Execução enviada para #{job.runner.name}.")
         |> push_navigate(to: ~p"/w/#{workspace.slug}/jobs/#{job.id}")}

      {:error, changeset} ->
        {:noreply, assign(socket, params: params, form: to_form(changeset, as: "job"))}
    end
  end

  # The newest `limit` jobs; one more is read to know whether there are more.
  defp load_jobs(socket) do
    limit = socket.assigns.limit
    jobs = Jobs.list_jobs(socket.assigns.current_scope.workspace, limit: limit + 1)

    assign(socket,
      jobs: Enum.take(jobs, limit),
      more: length(jobs) > limit,
      now: DateTime.utc_now()
    )
  end

  defp load_projects(socket) do
    workspace = socket.assigns.current_scope.workspace

    assign(socket,
      projects: Projects.list_projects(workspace),
      online: RunnerStatus.online_ids(workspace.id)
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      pending_decisions={@pending_decisions}
      notification_center={@notification_center}
      current_scope={@current_scope}
      workspaces={@workspaces}
      active={:jobs}
      title="Execuções"
    >
      <:action label="Nova execução" icon="hero-plus" on_click="open_new" primary testid="new-job" />

      <.record_list id="jobs" testid="jobs" empty={@jobs == []}>
        <.record_card
          :for={job <- @jobs}
          id={"job-row-#{job.id}"}
          testid={"job-row-#{job.id}"}
          navigate={~p"/w/#{@current_scope.workspace.slug}/jobs/#{job.id}"}
          link_testid={"job-link-#{job.id}"}
          tone={job_tone(job)}
        >
          <:leading><.record_icon icon="hero-command-line" /></:leading>
          <:title>{prompt_summary(job.prompt, 120)}</:title>
          <:badge><.job_status job={job} data-testid={"job-status-#{job.id}"} /></:badge>
          <:meta>
            <span :if={job.project}>{job.project.name}</span>
            <span :if={job.project}>·</span>
            <span>{if job.runner, do: job.runner.name, else: "—"}</span>
            <span :if={job.created_by_user}>· por {job.created_by_user.name}</span>
          </:meta>
          <:aside>
            <.record_metric label="Duração">{format_duration(job.duration_ms)}</.record_metric>
            <.record_metric label="Custo">{format_cost(job.cost_usd)}</.record_metric>
            <span>criada {time_ago(job.inserted_at, @now)}</span>
          </:aside>
        </.record_card>
        <:empty_state>
          <.record_empty
            testid="no-jobs"
            icon="hero-command-line"
            title="Nenhuma execução ainda"
            description="Envie um prompt para um projeto e acompanhe o agente trabalhando na máquina do runner."
          >
            <:actions>
              <.button icon="hero-plus" phx-click="open_new">Nova execução</.button>
            </:actions>
          </.record_empty>
        </:empty_state>
      </.record_list>
      <.load_more more={@more} testid="jobs-load-more" />

      <.modal
        :if={@creating}
        id="new-job-modal"
        title="Nova execução"
        max_width="lg"
        on_cancel={JS.push("close_new")}
      >
        <.alert :if={@projects == []} color="warning" class="mb-4" data-testid="job-no-projects">
          Este workspace ainda não tem projetos. Crie um em <.link
            navigate={~p"/w/#{@current_scope.workspace.slug}/projects/new"}
            class="underline"
          >Projetos</.link>: um diretório de código de um runner.
        </.alert>

        <.form for={@form} id="new-job-form" phx-change="validate" phx-submit="create">
          <.icon_field
            field={@form[:project_id]}
            icon="hero-folder-open"
            type="select"
            label="Projeto"
            prompt="Escolha um projeto"
            options={ProjectChoice.options(@projects, @online, :scratch)}
            data-testid="job-project"
          />
          <.alert
            :if={ProjectChoice.offline_runner(@projects, @online, @params["project_id"])}
            color="info"
            class="mb-4"
            with_icon
            data-testid="job-project-offline"
          >
            O runner {ProjectChoice.offline_runner(@projects, @online, @params["project_id"])} está offline: a execução fica na fila e começa quando ele conectar.
          </.alert>
          <.markdown_editor
            id="job-prompt"
            field={@form[:prompt]}
            label="Prompt"
            icon="hero-command-line"
            rows={6}
            placeholder="Ex.: crie um hello.txt com a data de hoje"
            help_text="O agente roda num worktree descartável do projeto, com permissões totais: as mudanças não ficam no repositório."
            testid="job-prompt"
          />
          <div class="flex flex-wrap justify-end gap-2">
            <.button type="button" variant="ghost" color="gray" phx-click="close_new">
              Cancelar
            </.button>
            <.button type="submit" icon="hero-paper-airplane" data-testid="job-submit">
              Enviar
            </.button>
          </div>
        </.form>
      </.modal>
    </Layouts.app>
    """
  end
end
