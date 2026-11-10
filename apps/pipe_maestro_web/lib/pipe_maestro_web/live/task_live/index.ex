defmodule PipeMaestroWeb.TaskLive.Index do
  @moduledoc """
  The workspace's tasks, newest first, searchable and updated live, and the
  form that starts one (empty, a copy of a task: `?duplicate=<id>`, or a task
  the agent wrote: `?proposta=<id>`, `PipeMaestro.Proposals`, or one for a
  project: `?project_id=<id>`): what to do, which pipeline, and which project
  it runs in (the project decides the runner and the directory; with the
  runner offline, the task waits for it). "Escrever com IA" asks the agent to write one from an idea. A
  proposal already turned into a task leads to that task instead.
  """
  use PipeMaestroWeb, :live_view

  # How many tasks a page shows, and how many more each "Carregar mais" adds.
  @page 30

  import PipeMaestroWeb.TaskComponents
  import PipeMaestroWeb.PipelineComponents, only: [pipeline_preview: 1]
  import PipeMaestroWeb.RunnerComponents, only: [time_ago: 2]

  alias Phoenix.Socket.Broadcast
  alias PipeMaestro.{Jobs, Pipelines, Projects, Proposals, Tasks}
  alias PipeMaestroWeb.{ProjectChoice, ProposalRequest, RunnerStatus}

  @impl true
  def mount(_params, _session, socket) do
    workspace = socket.assigns.current_scope.workspace

    if connected?(socket) do
      Tasks.subscribe({:workspace, workspace.id})
      Jobs.subscribe({:workspace, workspace.id})
      RunnerStatus.subscribe(workspace.id)
    end

    {:ok,
     socket
     |> assign(page_title: "Tarefas", creating: false, form: nil, params: %{}, query: "")
     |> assign(limit: @page)
     |> assign(proposal_request: nil, from_proposal: false, proposal_job: nil)
     |> assign(pipelines: Pipelines.list_pipelines(workspace))
     |> load_tasks()
     |> load_projects()}
  end

  @impl true
  def handle_params(%{"duplicate" => id}, _uri, socket) do
    task = Tasks.get_task!(socket.assigns.current_scope.workspace, id)
    params = task |> Tasks.duplicate_params() |> Map.new(fn {k, v} -> {k, v || ""} end)

    {:noreply,
     assign(socket,
       creating: true,
       from_proposal: false,
       proposal_job: nil,
       params: params,
       form: to_form(Tasks.change_task(params), as: "task")
     )}
  end

  def handle_params(%{"proposta" => id}, _uri, socket) do
    workspace = socket.assigns.current_scope.workspace

    with {:ok, _uuid} <- Ecto.UUID.cast(id),
         job = Proposals.get_proposal!(workspace, id),
         "task" <- Proposals.kind(job),
         nil <- Proposals.created_task_id(job),
         {:ok, result} <- Proposals.result(job) do
      params = Map.new(result.task_params, fn {k, v} -> {k, v || ""} end)

      {:noreply,
       assign(socket,
         creating: true,
         from_proposal: true,
         proposal_job: job,
         params: params,
         form: to_form(Tasks.change_task(params), as: "task")
       )}
    else
      task_id when is_binary(task_id) ->
        {:noreply, to_created_task(socket, task_id)}

      _no_task ->
        {:noreply, put_flash(socket, :error, "Esta proposta não tem uma tarefa pronta.")}
    end
  end

  def handle_params(%{"project_id" => id}, _uri, socket) do
    params = %{"project_id" => id}

    {:noreply,
     assign(socket,
       creating: true,
       from_proposal: false,
       proposal_job: nil,
       params: params,
       form: to_form(Tasks.change_task(params), as: "task")
     )}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:task_updated, _task}, socket), do: {:noreply, load_tasks(socket)}

  def handle_info(%Broadcast{event: "presence_diff"}, socket),
    do: {:noreply, load_projects(socket)}

  def handle_info(:runners_changed, socket), do: {:noreply, load_projects(socket)}

  def handle_info({:job_updated, _job}, socket), do: {:noreply, socket}

  @impl true
  def handle_event("open_new", _params, socket) do
    {:noreply,
     socket
     |> assign(creating: true, params: %{}, from_proposal: false, proposal_job: nil)
     |> assign(form: to_form(Tasks.change_task(), as: "task"))}
  end

  def handle_event("open_proposal_request", _params, socket),
    do: {:noreply, ProposalRequest.open(socket, "task")}

  def handle_event("close_proposal_request", _params, socket),
    do: {:noreply, ProposalRequest.close(socket)}

  def handle_event("validate_proposal_request", %{"proposal" => params}, socket),
    do: {:noreply, ProposalRequest.validate(socket, params)}

  def handle_event("submit_proposal_request", %{"proposal" => params}, socket),
    do: {:noreply, ProposalRequest.submit(socket, params)}

  def handle_event("search", %{"search" => %{"q" => query}}, socket),
    do: {:noreply, socket |> assign(query: query, limit: @page) |> load_tasks()}

  def handle_event("load_more", _params, socket),
    do: {:noreply, socket |> update(:limit, &(&1 + @page)) |> load_tasks()}

  def handle_event("close_new", _params, socket),
    do:
      {:noreply,
       assign(socket, creating: false, form: nil, from_proposal: false, proposal_job: nil)}

  def handle_event("validate", %{"task" => params}, socket) do
    form = params |> Tasks.change_task() |> Map.put(:action, :validate) |> to_form(as: "task")
    {:noreply, assign(socket, form: form, params: params)}
  end

  def handle_event("create", %{"task" => params}, socket) do
    %{user: user, workspace: workspace} = socket.assigns.current_scope

    result =
      case socket.assigns.proposal_job do
        nil -> Tasks.create_task(user, workspace, params)
        job -> Proposals.create_task(user, workspace, job, params)
      end

    case result do
      {:ok, task} ->
        {:noreply,
         socket
         |> put_flash(:info, "Tarefa iniciada em #{task.runner.name}.")
         |> push_navigate(to: ~p"/w/#{workspace.slug}/tasks/#{task.id}")}

      {:error, changeset} ->
        if Keyword.has_key?(changeset.errors, :proposal_job_id),
          do:
            {:noreply,
             to_created_task(socket, Proposals.created_task_id(socket.assigns.proposal_job))},
          else: {:noreply, assign(socket, form: to_form(changeset, as: "task"), params: params)}
    end
  end

  # A proposal becomes one task at most: once it has, it leads there.
  defp to_created_task(socket, task_id) do
    socket
    |> put_flash(:info, "Esta proposta já virou uma tarefa.")
    |> push_navigate(to: ~p"/w/#{socket.assigns.current_scope.workspace.slug}/tasks/#{task_id}")
  end

  # The newest `limit` tasks; one more is read to know whether there are more.
  defp load_tasks(socket) do
    limit = socket.assigns.limit

    tasks =
      Tasks.list_tasks(
        socket.assigns.current_scope.workspace,
        %{"q" => socket.assigns.query},
        limit: limit + 1
      )

    assign(socket,
      tasks: Enum.take(tasks, limit),
      more: length(tasks) > limit,
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
      active={:tasks}
      title="Tarefas"
    >
      <:action label="Nova tarefa" icon="hero-plus" on_click="open_new" primary testid="new-task" />
      <:action
        label="Escrever com IA"
        icon="hero-cpu-chip"
        on_click="open_proposal_request"
        testid="task-generate"
      />

      <.filter_bar>
        <.form
          for={to_form(%{"q" => @query}, as: "search")}
          id="tasks-search"
          phx-change="search"
          phx-submit="search"
          class="w-full sm:max-w-sm"
        >
          <.icon_field
            field={to_form(%{"q" => @query}, as: "search")[:q]}
            icon="hero-magnifying-glass"
            type="search"
            label="Buscar"
            hide_label
            placeholder="Buscar no título ou no pedido"
            phx-debounce="300"
            data-testid="tasks-search"
          />
        </.form>
      </.filter_bar>

      <.record_list id="tasks" testid="tasks" empty={@tasks == []}>
        <.record_card
          :for={task <- @tasks}
          id={"task-row-#{task.id}"}
          testid={"task-row-#{task.id}"}
          navigate={~p"/w/#{@current_scope.workspace.slug}/tasks/#{task.id}"}
          link_testid={"task-link-#{task.id}"}
          tone={task_tone(task)}
        >
          <:leading><.task_mark task={task} /></:leading>
          <:title>{task.title}</:title>
          <:badge><.task_status task={task} data-testid={"task-status-#{task.id}"} /></:badge>
          <:meta>
            <.record_fact icon="hero-squares-2x2" title="Pipeline">{task.pipeline_name}</.record_fact>
            <.record_fact icon="hero-folder" title="Projeto">
              {(task.project || %{})["name"] || task.directory}
            </.record_fact>
            <.record_fact icon="hero-server" title="Runner e diretório" mono>
              {if task.runner, do: task.runner.name, else: "—"}:{task.directory}
            </.record_fact>
          </:meta>
          <:aside>
            <.task_progress
              task={task}
              class="font-medium text-gray-700 dark:text-gray-200"
              testid={"task-progress-#{task.id}"}
            />
            <.record_metric icon="hero-calendar" title="Criada">
              {time_ago(task.inserted_at, @now)}
            </.record_metric>
          </:aside>
        </.record_card>
        <:empty_state>
          <.record_empty
            testid="no-tasks"
            icon="hero-queue-list"
            title={
              if @query in [nil, ""], do: "Nenhuma tarefa ainda", else: "Nenhuma tarefa encontrada"
            }
            description={
              if @query in [nil, ""],
                do:
                  "Cada tarefa percorre as etapas de um pipeline num runner. Escolha um pipeline e um projeto, e descreva o que deve ser feito.",
                else: "Nada no título ou no pedido com \"#{@query}\"."
            }
          >
            <:actions :if={@query in [nil, ""]}>
              <.button icon="hero-plus" phx-click="open_new">Nova tarefa</.button>
            </:actions>
          </.record_empty>
        </:empty_state>
      </.record_list>
      <.load_more more={@more} testid="tasks-load-more" />

      <.modal
        :if={@creating}
        id="new-task-modal"
        title="Nova tarefa"
        max_width="xl"
        on_cancel={JS.push("close_new")}
      >
        <.alert :if={@pipelines == []} color="warning" class="mb-4" data-testid="no-pipelines">
          Este workspace ainda não tem pipelines. Crie um em <.link
            navigate={~p"/w/#{@current_scope.workspace.slug}/pipelines"}
            class="underline"
          >Pipelines</.link>.
        </.alert>
        <.alert :if={@projects == []} color="warning" class="mb-4" data-testid="task-no-projects">
          Este workspace ainda não tem projetos. Crie um em <.link
            navigate={~p"/w/#{@current_scope.workspace.slug}/projects/new"}
            class="underline"
          >Projetos</.link>: um diretório de código de um runner.
        </.alert>

        <.alert
          :if={@from_proposal}
          color="info"
          class="mb-4"
          with_icon
          data-testid="task-from-proposal"
        >
          Esta é a tarefa que o agente escreveu. Revise, ajuste o que quiser e inicie.
        </.alert>

        <.form for={@form} id="new-task-form" phx-change="validate" phx-submit="create">
          <.icon_field
            field={@form[:title]}
            icon="hero-tag"
            label="Título"
            placeholder="Ex.: Botão de login não responde"
            data-testid="task-title"
          />
          <.markdown_editor
            id="task-prompt"
            field={@form[:prompt]}
            label="O que deve ser feito"
            icon="hero-pencil-square"
            rows={6}
            placeholder="Descreva o problema ou a mudança com o contexto que tiver."
            testid="task-prompt"
          />
          <.icon_field
            field={@form[:source_url]}
            icon="hero-link"
            label="Issue do GitHub (opcional)"
            placeholder="https://github.com/dono/repo/issues/42"
            help_text="Com um pipeline que abre PR, o PR fecha a issue e as decisões viram comentários nela."
            data-testid="task-issue-url"
          />
          <.icon_field
            field={@form[:pipeline_id]}
            icon="hero-squares-2x2"
            type="select"
            label="Pipeline"
            prompt="Escolha um pipeline"
            options={Enum.map(@pipelines, &{&1.name, &1.id})}
            data-testid="task-pipeline"
          />
          <.pipeline_preview
            pipelines={@pipelines}
            id={@form[:pipeline_id].value}
            testid="task-pipeline-preview"
          />
          <.icon_field
            field={@form[:project_id]}
            icon="hero-folder-open"
            type="select"
            label="Projeto"
            prompt="Escolha um projeto"
            options={ProjectChoice.options(@projects, @online, :task)}
            help_text="O projeto decide o runner e o diretório em que a tarefa roda."
            data-testid="task-project"
          />
          <.alert
            :if={ProjectChoice.offline_runner(@projects, @online, @params["project_id"])}
            color="info"
            class="mb-4"
            with_icon
            data-testid="task-project-offline"
          >
            O runner {ProjectChoice.offline_runner(@projects, @online, @params["project_id"])} está offline: a tarefa fica na fila e começa quando ele conectar.
          </.alert>
          <div class="flex flex-wrap justify-end gap-2">
            <.button type="button" variant="ghost" color="gray" phx-click="close_new">
              Cancelar
            </.button>
            <.button type="submit" icon="hero-play" data-testid="task-submit">Iniciar</.button>
          </div>
        </.form>
      </.modal>
      <ProposalRequest.request_modal :if={@proposal_request} request={@proposal_request} />
    </Layouts.app>
    """
  end
end
