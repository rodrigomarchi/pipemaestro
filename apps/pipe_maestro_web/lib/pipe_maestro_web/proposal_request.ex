defmodule PipeMaestroWeb.ProposalRequest do
  @moduledoc """
  The form that asks the agent for a proposal (`PipeMaestro.Proposals`),
  shared by the screens that offer one: pick a project (its runner studies its
  directory in a disposable worktree, so the directory must be git and the
  runner able to make one; with the runner offline, the request waits for
  it), and write the request. A screen
  keeps it in `:proposal_request` (nil when closed) and hands its events here:
  `open/3`, `validate/2` and `submit/2` (which navigates to the proposal), and
  renders `request_modal/1`.

  A task may be written for a pipeline the person picks (else the agent
  picks one), and is created and started without review unless the person
  turns that off (`auto_approve`, on by default here).
  """
  use PipeMaestroWeb, :html

  import Phoenix.LiveView, only: [push_navigate: 2]

  alias PipeMaestro.{Audit, Pipelines, Projects, Proposals}
  alias PipeMaestroWeb.{ChangesetErrors, ProjectChoice, RunnerStatus}

  @typedoc """
  The open form: its kind, fixed fields, form, typed params, the workspace's
  projects, the runners online and the workspace's pipelines (a task's).
  """
  @type t :: %{
          kind: String.t(),
          fixed: map(),
          form: Phoenix.HTML.Form.t(),
          params: map(),
          projects: [PipeMaestro.Projects.Project.t()],
          online: MapSet.t(),
          pipelines: [PipeMaestro.Pipelines.Pipeline.t()]
        }

  @doc """
  Opens the form for `kind`, with `fixed` fields (a pipeline to improve) and
  a `project_id` to start from.
  """
  @spec open(Phoenix.LiveView.Socket.t(), String.t(), keyword()) :: Phoenix.LiveView.Socket.t()
  def open(socket, kind, opts \\ []) do
    workspace = socket.assigns.current_scope.workspace
    fixed = Keyword.get(opts, :fixed, %{})

    params =
      if(opts[:project_id], do: %{"project_id" => opts[:project_id]}, else: %{})
      |> Map.merge(kind_defaults(kind))
      |> Map.merge(fixed)

    pipelines = if kind == "task", do: Pipelines.list_pipelines(workspace), else: []

    assign(socket,
      proposal_request: %{
        kind: kind,
        fixed: fixed,
        params: params,
        projects: Projects.list_projects(workspace),
        online: RunnerStatus.online_ids(workspace.id),
        pipelines: pipelines,
        form: to_form(Proposals.change_request(kind, workspace, params), as: "proposal")
      }
    )
  end

  # A task is created without review unless the person says otherwise.
  defp kind_defaults("task"), do: %{"auto_approve" => "true"}
  defp kind_defaults(_kind), do: %{}

  @doc "Closes the form."
  @spec close(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def close(socket), do: assign(socket, proposal_request: nil)

  @doc "Follows what is typed: a project whose runner is offline is pointed out."
  @spec validate(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def validate(socket, params) do
    %{kind: kind, fixed: fixed} = request = socket.assigns.proposal_request
    params = Map.merge(params, fixed)

    form =
      kind
      |> Proposals.change_request(socket.assigns.current_scope.workspace, params)
      |> Map.put(:action, :validate)
      |> to_form(as: "proposal")

    assign(socket, proposal_request: %{request | params: params, form: form})
  end

  @doc "Asks for the proposal and goes to it, or shows what is missing."
  @spec submit(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def submit(socket, params) do
    %{kind: kind, fixed: fixed} = request = socket.assigns.proposal_request
    %{user: user, workspace: workspace} = socket.assigns.current_scope
    params = Map.merge(params, fixed)

    case Proposals.request(kind, user, workspace, params) do
      {:ok, job} ->
        Audit.record(workspace, user, "proposal.requested", job)
        push_navigate(socket, to: ~p"/w/#{workspace.slug}/proposals/#{job.id}")

      {:error, changeset} ->
        form = changeset |> Map.put(:action, :insert) |> to_form(as: "proposal")
        assign(socket, proposal_request: %{request | params: params, form: form})
    end
  end

  @doc """
  Asks the agent to suggest the decision paused task `task_id` waits for,
  on the task's runner, and goes to the proposal; says why when it cannot.
  """
  @spec suggest_decision(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  def suggest_decision(socket, task_id) do
    %{user: user, workspace: workspace} = socket.assigns.current_scope

    case Proposals.request("decision", user, workspace, %{"task_id" => task_id}) do
      {:ok, job} ->
        Audit.record(workspace, user, "proposal.requested", job)
        push_navigate(socket, to: ~p"/w/#{workspace.slug}/proposals/#{job.id}")

      {:error, changeset} ->
        message =
          ChangesetErrors.to_text(changeset)

        Phoenix.LiveView.put_flash(socket, :error, "O agente não pôde sugerir: #{message}")
    end
  end

  # What each kind asks, beyond the project.
  defp copy("pipeline"),
    do: %{
      title: "Gerar pipeline com IA",
      intro:
        "O agente estuda o projeto pelo runner dele, num worktree descartável (nada muda no seu código), roda os comandos que encontrar e propõe um pipeline. Você revisa antes de salvar.",
      label: "O que o pipeline deve fazer",
      placeholder:
        "Ex.: implementar funcionalidades a partir de issues do GitHub, com testes, revisão e um PR no final."
    }

  defp copy("task"),
    do: %{
      title: "Escrever tarefa com IA",
      intro:
        "Conte a ideia do seu jeito. O agente estuda o projeto (num worktree descartável) e escreve a tarefa: título, contexto, arquivos envolvidos, critérios de aceite e o pipeline que serve. Com a criação sem revisão ligada, a tarefa já nasce e começa a rodar; você só é chamado se o agente tiver dúvidas ou a tarefa não puder ser criada.",
      label: "A ideia",
      placeholder: "Ex.: o login às vezes trava quando muita gente entra ao mesmo tempo."
    }

  defp copy("improve"),
    do: %{
      title: "Melhorar pipeline com IA",
      intro:
        "O agente lê como as últimas tarefas deste pipeline correram (falhas, gates, decisões, custo), estuda o projeto e propõe o pipeline revisado e as notas do projeto. Você revisa antes de salvar.",
      label: "Foco (opcional)",
      placeholder: "Ex.: está caro demais; ou: a etapa de testes falha muito."
    }

  @doc "The modal with the form; its events go to `validate/2` and `submit/2`."
  attr :request, :map, required: true, doc: "the open form (`t()`)"

  @spec request_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def request_modal(assigns) do
    assigns = assign(assigns, copy: copy(assigns.request.kind))

    ~H"""
    <.modal
      id="proposal-request-modal"
      title={@copy.title}
      max_width="xl"
      on_cancel={JS.push("close_proposal_request")}
    >
      <p class="mb-4 text-sm text-gray-600 dark:text-gray-300">{@copy.intro}</p>
      <.alert
        :if={@request.projects == []}
        color="warning"
        class="mb-4"
        data-testid="proposal-request-no-projects"
      >
        Este workspace ainda não tem projetos. Crie um em Projetos: um diretório de código de um runner.
      </.alert>
      <.form
        for={@request.form}
        id="proposal-request-form"
        phx-change="validate_proposal_request"
        phx-submit="submit_proposal_request"
      >
        <.icon_field
          field={@request.form[:project_id]}
          icon="hero-folder-open"
          type="select"
          label="Projeto"
          prompt="Escolha um projeto"
          options={ProjectChoice.options(@request.projects, @request.online, :scratch)}
          data-testid="proposal-request-project"
        />
        <.alert
          :if={
            ProjectChoice.offline_runner(
              @request.projects,
              @request.online,
              @request.params["project_id"]
            )
          }
          color="info"
          class="mb-4"
          with_icon
          data-testid="proposal-request-project-offline"
        >
          O runner {ProjectChoice.offline_runner(
            @request.projects,
            @request.online,
            @request.params["project_id"]
          )} está offline: o pedido fica na fila e o agente começa quando ele conectar.
        </.alert>
        <.markdown_editor
          :if={@request.kind in ["pipeline", "task"]}
          id="proposal-request-text"
          field={@request.form[:request]}
          label={@copy.label}
          icon="hero-chat-bubble-bottom-center-text"
          testid="proposal-request-text"
          rows={6}
          placeholder={@copy.placeholder}
        />
        <.icon_field
          :if={@request.kind == "task"}
          field={@request.form[:issue_url]}
          icon="hero-link"
          label="Issue do GitHub (opcional)"
          placeholder="https://github.com/dono/repo/issues/42"
          data-testid="proposal-request-issue-url"
        />
        <.icon_field
          :if={@request.kind == "task"}
          field={@request.form[:pipeline_id]}
          icon="hero-squares-2x2"
          type="select"
          label="Pipeline"
          prompt="Deixar o agente escolher"
          options={Enum.map(@request.pipelines, &{&1.name, &1.id})}
          data-testid="proposal-request-pipeline"
        />
        <.field
          :if={@request.kind == "task"}
          field={@request.form[:auto_approve]}
          type="switch"
          label="Criar e iniciar a tarefa sem revisão"
          help_text="Se o agente tiver dúvidas ou a tarefa não puder ser criada, ela fica para você revisar."
          data-testid="proposal-request-auto-approve"
        />
        <.markdown_editor
          :if={@request.kind == "improve"}
          id="proposal-request-focus"
          field={@request.form[:focus]}
          label={@copy.label}
          icon="hero-viewfinder-circle"
          testid="proposal-request-focus"
          rows={4}
          placeholder={@copy.placeholder}
        />
        <div class="flex justify-end gap-2">
          <.button type="button" variant="ghost" color="gray" phx-click="close_proposal_request">
            Cancelar
          </.button>
          <.button type="submit" icon="hero-cpu-chip" data-testid="proposal-request-submit">
            Pedir ao agente
          </.button>
        </div>
      </.form>
    </.modal>
    """
  end
end
