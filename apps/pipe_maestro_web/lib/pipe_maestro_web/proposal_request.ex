defmodule PipeMaestroWeb.ProposalRequest do
  @moduledoc """
  The form that asks the agent for a proposal (`PipeMaestro.Proposals`),
  shared by the screens that offer one: pick an online runner that can study
  a directory, one of its git directories, and write the request. A screen
  keeps it in `:proposal_request` (nil when closed) and hands its events here:
  `open/3`, `validate/2` and `submit/2` (which navigates to the proposal), and
  renders `request_modal/1`.

  A task may be written for a pipeline the person picks (else the agent
  picks one), and is created and started without review unless the person
  turns that off (`auto_approve`, on by default here).
  """
  use PipeMaestroWeb, :html

  import Phoenix.LiveView, only: [push_navigate: 2]

  alias PipeMaestro.{Audit, Pipelines, Proposals, Runners}
  alias PipeMaestroWeb.RunnerStatus

  @typedoc """
  The open form: its kind, fixed fields, form, typed params, online runners
  and the workspace's pipelines (a task's).
  """
  @type t :: %{
          kind: String.t(),
          fixed: map(),
          form: Phoenix.HTML.Form.t(),
          params: map(),
          runners: [PipeMaestro.Runners.Runner.t()],
          pipelines: [PipeMaestro.Pipelines.Pipeline.t()]
        }

  @doc """
  Opens the form for `kind`, with `fixed` fields (a pipeline to improve) and
  `defaults` (a directory to start from).
  """
  @spec open(Phoenix.LiveView.Socket.t(), String.t(), keyword()) :: Phoenix.LiveView.Socket.t()
  def open(socket, kind, opts \\ []) do
    workspace = socket.assigns.current_scope.workspace
    online = RunnerStatus.online_ids(workspace.id)
    runners = for r <- Runners.list_runners(workspace), MapSet.member?(online, r.id), do: r
    fixed = Keyword.get(opts, :fixed, %{})

    params =
      runners
      |> default_params(opts[:directory])
      |> Map.merge(kind_defaults(kind))
      |> Map.merge(fixed)

    pipelines = if kind == "task", do: Pipelines.list_pipelines(workspace), else: []

    assign(socket,
      proposal_request: %{
        kind: kind,
        fixed: fixed,
        params: params,
        runners: runners,
        pipelines: pipelines,
        form: to_form(Proposals.change_request(kind, workspace, params), as: "proposal")
      }
    )
  end

  # With a directory to start from, the first capable runner that offers it.
  defp default_params(_runners, nil), do: %{}

  defp default_params(runners, directory) do
    case Enum.find(runners, &(Proposals.capable?(&1) and Proposals.git_directory?(&1, directory))) do
      nil -> %{}
      runner -> %{"runner_id" => runner.id, "directory" => directory}
    end
  end

  # A task is created without review unless the person says otherwise.
  defp kind_defaults("task"), do: %{"auto_approve" => "true"}
  defp kind_defaults(_kind), do: %{}

  @doc "Closes the form."
  @spec close(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def close(socket), do: assign(socket, proposal_request: nil)

  @doc "Follows what is typed: the directories follow the runner picked."
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
          changeset
          |> Ecto.Changeset.traverse_errors(fn {msg, _opts} -> msg end)
          |> Map.values()
          |> List.flatten()
          |> Enum.join("; ")

        Phoenix.LiveView.put_flash(socket, :error, "O agente não pôde sugerir: #{message}")
    end
  end

  # What each kind asks, beyond the runner and directory.
  defp copy("pipeline"),
    do: %{
      title: "Gerar pipeline com IA",
      intro:
        "O agente estuda o diretório pelo runner, num worktree descartável (nada muda no seu código), roda os comandos que encontrar e propõe a configuração do projeto e um pipeline. Você revisa antes de salvar.",
      label: "O que o pipeline deve fazer",
      placeholder:
        "Ex.: implementar funcionalidades a partir de issues do GitHub, com testes, revisão e um PR no final."
    }

  defp copy("task"),
    do: %{
      title: "Escrever tarefa com IA",
      intro:
        "Conte a ideia do seu jeito. O agente estuda o diretório (num worktree descartável) e escreve a tarefa: título, contexto, arquivos envolvidos, critérios de aceite e o pipeline que serve. Com a criação sem revisão ligada, a tarefa já nasce e começa a rodar; você só é chamado se o agente tiver dúvidas ou a tarefa não puder ser criada.",
      label: "A ideia",
      placeholder: "Ex.: o login às vezes trava quando muita gente entra ao mesmo tempo."
    }

  defp copy("improve"),
    do: %{
      title: "Melhorar pipeline com IA",
      intro:
        "O agente lê como as últimas tarefas deste pipeline correram (falhas, gates, decisões, custo), estuda o diretório e propõe o pipeline revisado e as notas do projeto. Você revisa antes de salvar.",
      label: "Foco (opcional)",
      placeholder: "Ex.: está caro demais; ou: a etapa de testes falha muito."
    }

  # Runners that cannot study a directory are listed, but cannot be picked.
  defp runner_options(runners) do
    for runner <- runners do
      if Proposals.capable?(runner),
        do: [key: runner.name, value: runner.id],
        else: [key: "#{runner.name} (atualize o runner)", value: runner.id, disabled: true]
    end
  end

  # Only git directories can be studied: the agent works in a worktree.
  defp directory_options(runners, runner_id) do
    case Enum.find(runners, &(&1.id == runner_id)) do
      nil -> []
      runner -> for %{"name" => name, "git" => true} <- runner.directories, do: {name, name}
    end
  end

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
        :if={@request.runners == []}
        color="warning"
        class="mb-4"
        data-testid="proposal-request-no-runners"
      >
        Nenhum runner online. Conecte um em Executores.
      </.alert>
      <.form
        for={@request.form}
        id="proposal-request-form"
        phx-change="validate_proposal_request"
        phx-submit="submit_proposal_request"
      >
        <div class="grid gap-4 sm:grid-cols-2">
          <.icon_field
            field={@request.form[:runner_id]}
            icon="hero-server-stack"
            type="select"
            label="Runner"
            prompt="Escolha um runner online"
            options={runner_options(@request.runners)}
            data-testid="proposal-request-runner"
          />
          <.icon_field
            field={@request.form[:directory]}
            icon="hero-folder-open"
            type="select"
            label="Diretório (repositório git)"
            prompt="Escolha um diretório"
            options={directory_options(@request.runners, @request.params["runner_id"])}
            data-testid="proposal-request-directory"
          />
        </div>
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
