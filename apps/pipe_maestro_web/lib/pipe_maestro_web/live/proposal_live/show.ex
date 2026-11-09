defmodule PipeMaestroWeb.ProposalLive.Show do
  @moduledoc """
  One proposal (`PipeMaestro.Proposals`), drawn as a pipeline
  (`PipeMaestroWeb.PipelineComponents`): the request, the agent at work, the
  proposal and, once the agent ended, the way to ask again with a comment.
  Each place opens a drawer, kept in the URL as `?no=<place>`; every drawer
  stays on the page, hidden while closed, so the agent's timeline (a stream)
  keeps growing. The proposal's drawer opens on its own when it is ready: on
  arriving at a proposal already answered, and when the agent finishes.

  The proposal's drawer holds the review of its kind
  (`PipeMaestroWeb.ProposalComponents`), and what the person can do with it:

    * project: review the project form filled with the answer and save it
      (nothing is saved before), on the runner and directory asked;
    * pipeline: open the pipeline form filled with the proposal;
    * task: open the new-task form filled with it;
    * decision: apply the suggested decision (retry, advance or cancel), with
      the instructions as the person left them;
    * improve: save the project's notes, then open the pipeline's form filled
      with the revision.

  Any kind can be asked again with the person's comment.
  """
  use PipeMaestroWeb, :live_view

  alias PipeMaestroWeb.IntegrationComponents

  import PipeMaestroWeb.JobComponents
  import PipeMaestroWeb.ProposalComponents
  import PipeMaestroWeb.PipelineComponents, only: [place_node: 1, rail_item: 1, side_panel: 1]

  alias PipeMaestro.{Audit, Jobs, Pipelines, Projects, Proposals, Tasks}
  alias PipeMaestro.Jobs.Job
  alias PipeMaestro.Pipelines.Pipeline
  alias PipeMaestro.Projects.Project
  alias PipeMaestro.Proposals.DecisionKind
  alias PipeMaestroWeb.{ChangesetErrors, Markdown, PipelineExplorer, QuestionnaireComponents}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    workspace = socket.assigns.current_scope.workspace
    job = Proposals.get_proposal!(workspace, id)

    if can_review?(socket.assigns.current_scope, Proposals.kind(job)) do
      job = if connected?(socket), do: subscribe(workspace, job), else: job

      segments = job |> Jobs.list_events() |> timeline_items("all")

      {:ok,
       socket
       |> assign(page_title: "Proposta do agente", job: job, kind: Proposals.kind(job))
       |> assign(input: Proposals.input(job), title: Proposals.title(job))
       |> assign(typing: nil, timeline_tail: timeline_tail(segments), feedback_form: nil)
       |> assign(node: nil, routed: false)
       |> assign_result()
       |> stream(:timeline, segments)}
    else
      {:ok,
       socket
       |> put_flash(:error, "Só admins do workspace revisam esta proposta.")
       |> push_navigate(to: ~p"/w/#{workspace.slug}/proposals")}
    end
  end

  @nodes ~w(pedido agente proposta ajustes)

  # The old tabs (`?aba=`) lead to the place that holds them now.
  @tab_nodes %{"proposta" => "proposta", "agente" => "agente", "resumo" => "pedido"}

  # Without `no`, the page opens on the proposal when it is ready; once the
  # person has moved around, no place opens on its own.
  @impl true
  def handle_params(params, _uri, socket) do
    node =
      cond do
        params["no"] in @nodes -> params["no"]
        Map.has_key?(@tab_nodes, params["aba"]) -> Map.fetch!(@tab_nodes, params["aba"])
        not socket.assigns.routed and ready?(socket.assigns) -> "proposta"
        true -> nil
      end

    node = if node == "ajustes" and Job.active?(socket.assigns.job), do: nil, else: node

    {:noreply,
     socket
     |> assign(node: node, routed: true)
     |> assign(
       feedback_form: if(node == "ajustes", do: to_form(%{"feedback" => ""}, as: "round"))
     )}
  end

  defp ready?(%{result: result, error: error}), do: not is_nil(result) or not is_nil(error)

  defp node_path(%Phoenix.LiveView.Socket{assigns: assigns}, node),
    do: node_path(assigns.current_scope.workspace.slug, assigns.job, node)

  defp node_path(slug, job, nil), do: ~p"/w/#{slug}/proposals/#{job.id}"
  defp node_path(slug, job, node), do: ~p"/w/#{slug}/proposals/#{job.id}?#{[no: node]}"

  # Subscribe before reading again, so nothing that happens in between is
  # missed. A suggested decision follows its task: once decided, it no longer
  # applies.
  defp subscribe(workspace, job) do
    Jobs.subscribe({:job, job.id})
    task_id = Proposals.input(job)["task_id"]
    if task_id, do: Tasks.subscribe({:task, task_id})
    Proposals.get_proposal!(workspace, job.id)
  end

  defp may_cancel_job?(scope, job),
    do: scope.role == :admin or job.created_by_user_id == scope.user.id

  # Tasks and decisions are anyone's who runs tasks; pipelines are admins'.
  defp can_review?(scope, kind) when kind in ["task", "decision", "analysis"],
    do: can?(scope, :run_tasks)

  defp can_review?(scope, _kind), do: can?(scope, :manage_pipelines)

  defp assign_result(%{assigns: %{job: job}} = socket) do
    socket =
      assign(socket,
        result: nil,
        error: nil,
        form: nil,
        project: nil,
        task: nil,
        current: false,
        created_task_id: nil,
        auto_approve: nil,
        proposed: nil,
        current_pipeline: nil
      )

    if Job.active?(job) do
      socket
    else
      case Proposals.result(job) do
        {:ok, result} -> socket |> assign(result: result) |> assign_review(socket.assigns.kind)
        {:error, message} -> assign(socket, error: message)
      end
    end
  end

  # The project form, filled with the answer, for the runner's directory asked.
  defp assign_review(%{assigns: %{result: result}} = socket, "project") do
    project = %Project{workspace_id: socket.assigns.current_scope.workspace.id}

    assign(socket,
      project: project,
      form: to_form(Projects.change_project(project, result.project))
    )
  end

  defp assign_review(%{assigns: %{result: result}} = socket, "pipeline"),
    do: assign(socket, proposed: proposed(result.pipeline), current_pipeline: nil)

  defp assign_review(%{assigns: %{result: result}} = socket, "decision") do
    task = Tasks.get_task!(socket.assigns.current_scope.workspace, result.task_id)

    assign(socket,
      task: task,
      current: DecisionKind.current?(socket.assigns.input, task),
      form:
        to_form(
          %{"instructions" => result.instructions, "choice" => result.choice || ""},
          as: "decision"
        )
    )
  end

  defp assign_review(%{assigns: %{result: result}} = socket, "improve") do
    project =
      result.project_id &&
        Projects.get_project(socket.assigns.current_scope.workspace, result.project_id)

    assign(socket,
      project: project,
      form: to_form(%{"notes" => result.notes}, as: "notes"),
      proposed: proposed(result.pipeline),
      current_pipeline:
        Pipelines.get_pipeline(socket.assigns.current_scope.workspace.id, result.pipeline_id)
    )
  end

  # An analysis is answered on its task; here it is only read.
  defp assign_review(%{assigns: %{result: result}} = socket, "analysis") do
    task = Tasks.get_task!(socket.assigns.current_scope.workspace, result.task_id)
    assign(socket, task: task, current: DecisionKind.current?(socket.assigns.input, task))
  end

  # The task the proposal became (on its own or by hand), or why it was left
  # for review.
  defp assign_review(%{assigns: %{job: job}} = socket, "task") do
    assign(socket,
      created_task_id: Proposals.created_task_id(job),
      auto_approve: Proposals.auto_approve(job)
    )
  end

  # The pipeline the agent proposed (a form's attributes), as one to draw.
  defp proposed(attrs),
    do: %Pipeline{} |> Pipelines.change_pipeline(attrs) |> Ecto.Changeset.apply_changes()

  defp compare(nil), do: []
  defp compare(pipeline), do: [compare_to: pipeline]

  @impl true
  def handle_info({:job_updated, %Job{} = job}, socket) do
    created_before = socket.assigns.created_task_id

    was_ready = ready?(socket.assigns)

    socket =
      socket
      |> assign(job: job, typing: if(Job.active?(job), do: socket.assigns.typing))
      |> assign_result()

    # The agent just finished: its proposal opens, unless another place is open.
    socket =
      if not was_ready and ready?(socket.assigns) and is_nil(socket.assigns.node),
        do: assign(socket, node: "proposta"),
        else: socket

    {:noreply, follow_created_task(socket, created_before)}
  end

  def handle_info({:task_updated, _task}, %{assigns: %{task: %Tasks.Task{} = task}} = socket) do
    task = Tasks.get_task!(socket.assigns.current_scope.workspace, task.id)

    {:noreply,
     assign(socket, task: task, current: DecisionKind.current?(socket.assigns.input, task))}
  end

  # The task changed before the agent answered: the review reads it then.
  def handle_info({:task_updated, _task}, socket), do: {:noreply, socket}

  def handle_info({:job_telemetry, _id}, socket), do: {:noreply, socket}

  def handle_info({:job_delta, _id, text}, socket), do: {:noreply, assign(socket, typing: text)}

  def handle_info({:job_event, event}, socket) do
    case timeline_push(socket.assigns.timeline_tail, event) do
      {:seen, _tail} ->
        {:noreply, socket}

      {segment, tail} ->
        {:noreply,
         socket
         |> stream_insert(:timeline, segment)
         |> assign(timeline_tail: tail, typing: nil)}
    end
  end

  @impl true
  def handle_event("cancel", _params, socket) do
    if may_cancel_job?(socket.assigns.current_scope, socket.assigns.job),
      do: cancel_job(socket),
      else:
        {:noreply, put_flash(socket, :error, "Só quem pediu a proposta ou um admin a cancela.")}
  end

  # Project: the form filled with the answer, saved only now.
  def handle_event("validate_project", %{"project" => params}, socket) do
    changeset =
      socket.assigns.project
      |> Projects.change_project(with_place(params, socket))
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("save_project", %{"project" => params}, socket) do
    %{workspace: workspace, user: user} = socket.assigns.current_scope

    case Projects.create_project(workspace, with_place(params, socket)) do
      {:ok, project} ->
        Audit.record(workspace, user, "project.saved", project)

        {:noreply,
         socket
         |> put_flash(:info, "Projeto #{project.name} salvo.")
         |> push_navigate(to: ~p"/w/#{workspace.slug}/projects")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  # Decision: apply it, if the task still waits for this very decision.
  def handle_event("apply_decision", %{"action" => action} = params, socket)
      when action in ~w(retry advance cancel) do
    %{current_scope: scope, input: input} = socket.assigns
    task = Tasks.get_task!(scope.workspace, socket.assigns.task.id)

    cond do
      not DecisionKind.current?(input, task) ->
        {:noreply,
         socket
         |> assign(task: task, current: false)
         |> put_flash(:error, "A tarefa não espera mais esta decisão.")}

      action == "cancel" and not can?(scope, :cancel_task, task) ->
        {:noreply, put_flash(socket, :error, "Só quem criou a tarefa ou um admin a cancela.")}

      true ->
        decide(socket, task, action, params["decision"] || %{})
    end
  end

  def handle_event("apply_decision", _params, socket),
    do: {:noreply, put_flash(socket, :error, "Escolha tentar de novo, avançar ou cancelar.")}

  # Improve: the notes, then the pipeline.
  def handle_event("save_notes", %{"notes" => %{"notes" => notes}}, socket) do
    %{workspace: workspace, user: user} = socket.assigns.current_scope

    case Projects.update_project(socket.assigns.project, %{"notes" => notes}) do
      {:ok, project} ->
        Audit.record(workspace, user, "project.saved", project)

        {:noreply,
         socket
         |> assign(project: project)
         |> put_flash(:info, "Notas de #{project.name} salvas.")}

      {:error, changeset} ->
        message = changeset.errors |> Keyword.values() |> Enum.map_join("; ", &elem(&1, 0))
        {:noreply, put_flash(socket, :error, "As notas não foram salvas: #{message}")}
    end
  end

  # Any kind: ask again with a comment.
  def handle_event("close_panel", _params, socket),
    do: {:noreply, push_patch(socket, to: node_path(socket, nil))}

  def handle_event("regenerate", %{"round" => %{"feedback" => feedback}}, socket) do
    %{workspace: workspace, user: user} = socket.assigns.current_scope
    %{job: job, kind: kind, input: input} = socket.assigns
    attrs = Map.merge(input, %{"runner_id" => job.runner_id, "feedback" => feedback})

    case Proposals.request(kind, user, workspace, attrs, job) do
      {:ok, next} ->
        Audit.record(workspace, user, "proposal.requested", next)
        {:noreply, push_navigate(socket, to: ~p"/w/#{workspace.slug}/proposals/#{next.id}")}

      {:error, changeset} ->
        message =
          ChangesetErrors.to_text(changeset)

        {:noreply, put_flash(socket, :error, "Não foi possível pedir de novo: #{message}")}
    end
  end

  defp cancel_job(socket) do
    case Jobs.request_cancel(socket.assigns.job) do
      {:ok, job} -> {:noreply, assign(socket, job: job)}
      {:error, :finished} -> {:noreply, put_flash(socket, :error, "O agente já terminou.")}
    end
  end

  defp decide(socket, task, action, decision) do
    %{user: user, workspace: workspace} = socket.assigns.current_scope
    instructions = blank_to_nil(decision["instructions"])
    opts = [by: user, choice: blank_to_nil(decision["choice"])]

    result =
      case action do
        "retry" -> Tasks.retry_stage(task, instructions, opts)
        "advance" -> Tasks.advance(task, instructions, opts)
        "cancel" -> Tasks.cancel_task(task, by: user)
      end

    case result do
      {:ok, task} ->
        {:noreply,
         socket
         |> put_flash(:info, "Decisão aplicada: #{action_label(action)}.")
         |> push_navigate(to: ~p"/w/#{workspace.slug}/tasks/#{task.id}")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "A tarefa não espera mais esta decisão.")}
    end
  end

  # The directory is the one studied, not a field the person changes here.
  # The runner and the directory are the ones the proposal was asked about.
  defp with_place(params, socket),
    do: Map.merge(params, Map.take(socket.assigns.result.project, ~w(runner_id directory)))

  defp blank_to_nil(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: value)

  defp blank_to_nil(_value), do: nil

  # Whoever asked is taken to the task the proposal just became on its own.
  defp follow_created_task(%{assigns: %{created_task_id: nil}} = socket, _before), do: socket

  defp follow_created_task(%{assigns: %{created_task_id: id, job: job}} = socket, nil) do
    %{user: user, workspace: workspace} = socket.assigns.current_scope

    if job.created_by_user_id == user.id do
      socket
      |> put_flash(:info, "Tarefa criada e iniciada.")
      |> push_navigate(to: task_link(workspace, id))
    else
      socket
    end
  end

  defp follow_created_task(socket, _before), do: socket

  defp task_link(workspace, task_id), do: ~p"/w/#{workspace.slug}/tasks/#{task_id}"

  # What the proposal's place says: where it stands.
  defp proposal_state(_job, _result, _error, id) when is_binary(id), do: "Virou uma tarefa."
  defp proposal_state(_job, _result, error, _id) when is_binary(error), do: error

  defp proposal_state(_job, result, _error, _id) when not is_nil(result),
    do: "Pronta para revisar."

  defp proposal_state(job, _result, _error, _id),
    do:
      if(Job.active?(job),
        do: "Aparece aqui quando o agente terminar.",
        else: "A execução terminou sem proposta."
      )

  defp kind_label(kind), do: Proposals.kind_module(kind).label()

  defp first_line(nil), do: nil

  defp first_line(text) do
    text
    |> String.split("\n", trim: true)
    |> Enum.find("", &(String.trim(&1) != ""))
    |> String.replace(~r/^[#>\-*\s]+/, "")
  end

  defp last_line(text),
    do: text |> String.split("\n", trim: true) |> List.last() |> Kernel.||("")

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      pending_decisions={@pending_decisions}
      notification_center={@notification_center}
      current_scope={@current_scope}
      workspaces={@workspaces}
      active={:proposals}
      focus={Job.active?(@job)}
      title={@title}
      back={
        %{
          to: ~p"/w/#{@current_scope.workspace.slug}/proposals",
          label: "Propostas",
          testid: "back-to-proposals"
        }
      }
    >
      <:status>
        <.kind_badge kind={@kind} data-testid="proposal-kind" />
        <.job_status job={@job} data-testid="proposal-status" />
      </:status>
      <:action
        :if={Job.active?(@job)}
        label="Cancelar"
        icon="hero-stop"
        on_click="cancel"
        disabled={!may_cancel_job?(@current_scope, @job)}
        danger
        testid="proposal-cancel"
      />

      <.card variant="outline">
        <.card_content>
          <ol class="relative" data-testid="proposal-overview">
            <.rail_item icon="hero-bolt" tone={:primary}>
              <.place_node
                title="Pedido"
                path={node_path(@current_scope.workspace.slug, @job, "pedido")}
                open={@node == "pedido"}
                testid="proposal-node-pedido"
              >
                {first_line(@input["request"] || @input["focus"]) || kind_label(@kind)}
                <span :if={@input["directory"]}>· {@input["directory"]}</span>
                <span :if={@job.runner}>· em {@job.runner.name}</span>
              </.place_node>
            </.rail_item>

            <.rail_item icon="hero-cpu-chip" tone={if Job.active?(@job), do: :delivery, else: :done}>
              <.place_node
                title="Agente"
                path={node_path(@current_scope.workspace.slug, @job, "agente")}
                open={@node == "agente"}
                tone={if Job.active?(@job), do: :running}
                truncate={false}
                testid="proposal-node-agente"
              >
                <:badge><.job_status job={@job} /></:badge>
                <p class="truncate">
                  {cond do
                    @job.status == :queued -> "Aguardando o runner começar…"
                    Job.active?(@job) -> "Estudando o projeto e escrevendo a proposta."
                    true -> "Terminou"
                  end}
                  <span :if={@job.duration_ms}>· {format_duration(@job.duration_ms)}</span>
                  <span :if={@job.cost_usd}>· {format_cost(@job.cost_usd)}</span>
                </p>
                <p
                  :if={@typing}
                  class="mt-0.5 truncate italic text-gray-600 dark:text-gray-300"
                  data-testid="proposal-node-typing"
                >
                  {last_line(@typing)}
                </p>
              </.place_node>
            </.rail_item>

            <.rail_item
              icon="hero-light-bulb"
              tone={if @result, do: :done, else: :neutral}
              last={Job.active?(@job)}
              dashed
            >
              <.place_node
                title="Proposta"
                path={node_path(@current_scope.workspace.slug, @job, "proposta")}
                open={@node == "proposta"}
                tone={if @result && !@created_task_id, do: :ready}
                truncate={false}
                testid="proposal-node-proposta"
              >
                <p class={["line-clamp-2", @error && "text-danger-700 dark:text-danger-400"]}>
                  {proposal_state(@job, @result, @error, @created_task_id)}
                </p>
              </.place_node>
            </.rail_item>

            <.rail_item :if={!Job.active?(@job)} icon="hero-arrow-path" tone={:ghost} last>
              <.place_node
                title="Pedir de novo com ajustes"
                path={node_path(@current_scope.workspace.slug, @job, "ajustes")}
                open={@node == "ajustes"}
                ghost
                testid="proposal-node-ajustes"
              >
                O agente refaz a proposta com o seu comentário.
              </.place_node>
            </.rail_item>
          </ol>
        </.card_content>
      </.card>

      <.side_panel
        id="proposal-drawer-proposta"
        title={kind_label(@kind)}
        open={@node == "proposta"}
        testid="proposal-drawer-proposta"
      >
        <p
          :if={!@result and !@error}
          class="text-sm text-gray-500 dark:text-gray-400"
          data-testid="proposal-pending"
        >
          {if Job.active?(@job),
            do: "O agente ainda está trabalhando: a proposta aparece aqui quando ele terminar.",
            else: "A execução terminou sem proposta."}
        </p>
        <.alert :if={@error} color="danger" class="mb-6" data-testid="proposal-error">
          {@error}
        </.alert>

        <.project_review
          :if={@result && @kind == "project"}
          result={@result}
          form={@form}
          input={@input}
        />
        <.pipeline_review
          :if={@result && @kind == "pipeline"}
          result={@result}
          proposed={@proposed}
          job={@job}
          workspace={@current_scope.workspace}
        />
        <.task_review
          :if={@result && @kind == "task"}
          result={@result}
          job={@job}
          workspace={@current_scope.workspace}
          created_task_id={@created_task_id}
          auto_approve={@auto_approve}
        />
        <.decision_review
          :if={@result && @kind == "decision"}
          result={@result}
          form={@form}
          task={@task}
          current={@current}
          may_cancel={@task && can?(@current_scope, :cancel_task, @task)}
        />
        <.analysis_review
          :if={@result && @kind == "analysis"}
          result={@result}
          task={@task}
          current={@current}
          workspace={@current_scope.workspace}
        />
        <.improve_review
          :if={@result && @kind == "improve"}
          result={@result}
          proposed={@proposed}
          current={@current_pipeline}
          form={@form}
          project={@project}
          input={@input}
          job={@job}
          workspace={@current_scope.workspace}
        />
      </.side_panel>

      <.side_panel
        id="proposal-drawer-agente"
        title="Como o agente trabalhou"
        description={if Job.active?(@job), do: "Ao vivo, enquanto ele estuda e escreve."}
        open={@node == "agente"}
        testid="proposal-drawer-agente"
      >
        <p
          :if={@job.status == :queued}
          class="text-sm text-gray-500 dark:text-gray-400"
          data-testid="proposal-waiting"
        >
          Aguardando o runner começar…
        </p>
        <ol id="proposal-events" phx-update="stream" class="space-y-4" data-testid="proposal-events">
          <.timeline_segment
            :for={{id, segment} <- @streams.timeline}
            id={id}
            timeline="proposal-events"
            segment={segment}
          />
        </ol>
        <.typing :if={@typing} text={@typing} />
      </.side_panel>

      <.side_panel
        id="proposal-drawer-pedido"
        title="Pedido"
        open={@node == "pedido"}
        testid="proposal-drawer-pedido"
      >
        <p class="flex flex-wrap items-center gap-x-4 gap-y-1 text-sm text-gray-500 dark:text-gray-400">
          <span :if={@input["directory"]} class="flex items-center gap-1">
            <.icon name="hero-folder-open" class="size-4" />
            <span data-testid="proposal-directory">{@input["directory"]}</span>
          </span>
          <span :if={@job.runner}>no runner {@job.runner.name}</span>
          <a
            :if={@input["issue_url"]}
            href={@input["issue_url"]}
            target="_blank"
            rel="noopener"
            class="flex items-center gap-1 text-primary-600 hover:underline dark:text-primary-400"
            data-testid="proposal-issue"
          >
            {IntegrationComponents.issue_label(@input["issue_url"])}
            <.icon name="hero-arrow-top-right-on-square" class="size-3" />
          </a>
          <span :if={@job.cost_usd}>{format_cost(@job.cost_usd)}</span>
          <span :if={@job.duration_ms}>{format_duration(@job.duration_ms)}</span>
          <.link
            :if={@input["task_id"]}
            navigate={task_link(@current_scope.workspace, @input["task_id"])}
            class="text-primary-600 hover:underline dark:text-primary-400"
            data-testid="proposal-task-link"
          >
            ver a tarefa
          </.link>
        </p>
        <div
          :if={@input["request"] || @input["focus"]}
          id="proposal-request"
          class="prose prose-sm mt-4 max-w-none text-gray-600 dark:prose-invert dark:text-gray-300"
          data-testid="proposal-request"
        >
          {Markdown.to_html(@input["request"] || @input["focus"])}
        </div>
      </.side_panel>

      <.side_panel
        id="proposal-drawer-ajustes"
        title="Pedir de novo com ajustes"
        open={@node == "ajustes"}
        testid="proposal-drawer-ajustes"
      >
        <.form :if={@feedback_form} for={@feedback_form} id="feedback-form" phx-submit="regenerate">
          <.markdown_editor
            id="proposal-feedback"
            field={@feedback_form[:feedback]}
            label="O que mudar na proposta"
            icon="hero-chat-bubble-left-ellipsis"
            testid="proposal-feedback"
            rows={8}
          />
          <div class="flex justify-end">
            <.button type="submit" icon="hero-arrow-path" data-testid="proposal-feedback-submit">
              Pedir de novo
            </.button>
          </div>
        </.form>
      </.side_panel>
    </Layouts.app>
    """
  end

  attr :result, :map, required: true
  attr :proposed, Pipeline, required: true, doc: "the pipeline proposed, to draw"
  attr :job, :any, required: true
  attr :workspace, :any, required: true

  defp pipeline_review(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="grid gap-6 xl:grid-cols-2">
        <.markdown_card
          id="proposal-analysis"
          icon="hero-magnifying-glass"
          title="O que o agente entendeu do projeto"
          markdown={@result.analysis}
          testid="proposal-analysis"
        />
        <.checks checks={@result.checks} />
      </div>
      <div class="space-y-6">
        <.card variant="outline">
          <.card_content>
            <.section_heading
              icon="hero-squares-2x2"
              title={"Pipeline: #{@result.pipeline["name"]}"}
              description={@result.pipeline["description"]}
            />
            <.live_component
              module={PipelineExplorer}
              id="proposal-explorer"
              pipeline={@proposed}
              testid="proposal"
            />
            <div class="mt-4 flex justify-end">
              <.button
                link_type="live_redirect"
                to={~p"/w/#{@workspace.slug}/pipelines/new?proposta=#{@job.id}"}
                icon="hero-arrow-right-circle"
                data-testid="proposal-open-pipeline"
              >
                Revisar o pipeline
              </.button>
            </div>
          </.card_content>
        </.card>
      </div>
    </div>
    """
  end

  attr :result, :map, required: true
  attr :form, :any, required: true
  attr :input, :map, required: true

  defp project_review(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="grid gap-6 xl:grid-cols-2">
        <.markdown_card
          id="proposal-analysis"
          icon="hero-magnifying-glass"
          title="O que o agente entendeu do projeto"
          markdown={@result.analysis}
          testid="proposal-analysis"
        />
        <.checks checks={@result.checks} />
      </div>

      <.card variant="outline">
        <.card_content>
          <.section_heading
            icon="hero-folder-open"
            title="Projeto"
            description={"Como #{@input["directory"]} instala, testa e faz lint: as etapas usam esses comandos."}
          />
          <.form
            for={@form}
            id="proposal-project-form"
            data-testid="proposal-project-form"
            phx-change="validate_project"
            phx-submit="save_project"
          >
            <div class="grid gap-4 md:grid-cols-2">
              <.icon_field
                field={@form[:name]}
                icon="hero-tag"
                label="Nome"
                data-testid="proposal-project-name"
              />
              <.icon_field
                field={@form[:setup_command]}
                icon="hero-play"
                label="Comando de setup"
                data-testid="proposal-project-setup"
              />
              <.icon_field
                field={@form[:test_command]}
                icon="hero-beaker"
                label="Comando de testes"
                data-testid="proposal-project-test"
              />
              <.icon_field
                field={@form[:lint_command]}
                icon="hero-sparkles"
                label="Comando de lint"
                data-testid="proposal-project-lint"
              />
            </div>
            <.icon_field
              field={@form[:copy_paths_text]}
              icon="hero-document-duplicate"
              type="textarea"
              rows="3"
              label="Copiar para o worktree (um por linha)"
              data-testid="proposal-project-copy-paths"
            />
            <.markdown_editor
              id="proposal-project-notes"
              field={@form[:notes]}
              label="Notas para os agentes"
              icon="hero-light-bulb"
              testid="proposal-project-notes"
              rows={6}
            />
            <div class="flex justify-end">
              <.button
                type="submit"
                icon="hero-check"
                data-testid="proposal-save-project"
              >
                Salvar projeto
              </.button>
            </div>
          </.form>
        </.card_content>
      </.card>
    </div>
    """
  end

  attr :result, :map, required: true
  attr :job, :any, required: true
  attr :workspace, :any, required: true
  attr :created_task_id, :string, default: nil
  attr :auto_approve, :map, default: nil

  defp task_review(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="space-y-6">
        <.card variant="outline">
          <.card_content>
            <.section_heading icon="hero-queue-list" title="A tarefa proposta" />
            <h3
              class="border-b border-gray-200 pb-3 text-xl font-semibold text-gray-900 dark:border-gray-700 dark:text-white"
              data-testid="proposal-task-title"
            >
              {@result.title}
            </h3>
            <div
              id="proposal-task-prompt"
              phx-hook="Highlight"
              class="prose prose-sm mt-3 max-w-none dark:prose-invert"
              data-testid="proposal-task-prompt"
            >
              {Markdown.to_html(@result.prompt)}
            </div>
            <.alert
              :if={!@created_task_id && @auto_approve && @auto_approve["status"] == "skipped"}
              color="warning"
              class="mt-5"
              data-testid="proposal-auto-approve-skipped"
            >
              <p class="font-medium">Não foi criada automaticamente:</p>
              <div class="prose prose-sm max-w-none text-inherit dark:prose-invert">
                {Markdown.to_html(@auto_approve["reason"])}
              </div>
            </.alert>
            <div class="mt-5 flex justify-end">
              <.button
                :if={@created_task_id}
                link_type="live_redirect"
                to={task_link(@workspace, @created_task_id)}
                icon="hero-arrow-right-circle"
                data-testid="proposal-created-task-link"
              >
                Abrir a tarefa
              </.button>
              <.button
                :if={!@created_task_id}
                link_type="live_redirect"
                to={~p"/w/#{@workspace.slug}/tasks?proposta=#{@job.id}"}
                icon="hero-arrow-right-circle"
                data-testid="proposal-create-task"
              >
                Revisar e criar a tarefa
              </.button>
            </div>
          </.card_content>
        </.card>
      </div>
      <div class="grid gap-6 xl:grid-cols-2">
        <.card variant="outline">
          <.card_content>
            <.section_heading icon="hero-check-badge" title="Pronta para rodar?" />
            <.badge
              :if={@result.ready}
              color="success"
              variant="soft"
              label="Sim, está clara"
              data-testid="proposal-task-ready"
            />
            <.badge
              :if={!@result.ready}
              color="warning"
              variant="soft"
              label="Ainda não: responda antes"
              data-testid="proposal-task-ready"
            />
            <ul
              :if={@result.questions != []}
              class="mt-3 list-disc space-y-1 pl-5 text-sm text-gray-700 dark:text-gray-200"
              data-testid="proposal-task-questions"
            >
              <li :for={question <- @result.questions}>{Markdown.inline_html(question)}</li>
            </ul>
            <p
              class="mt-4 flex items-center gap-1.5 text-sm text-gray-600 dark:text-gray-300"
              data-testid="proposal-task-pipeline"
            >
              <.icon name="hero-squares-2x2" class="size-4 text-gray-400" />
              {cond do
                @result.pipeline ->
                  "Pipeline: #{@result.pipeline.name}"

                @result.pipeline_name != "" ->
                  "Pipeline sugerido \"#{@result.pipeline_name}\" não existe"

                true ->
                  "Sem pipeline sugerido"
              end}
            </p>
          </.card_content>
        </.card>
        <.markdown_card
          id="proposal-analysis"
          icon="hero-magnifying-glass"
          title="O que o agente entendeu"
          markdown={@result.analysis}
          testid="proposal-analysis"
        />
      </div>
    </div>
    """
  end

  attr :result, :map, required: true
  attr :task, :any, required: true
  attr :current, :boolean, required: true
  attr :workspace, :any, required: true

  defp analysis_review(assigns) do
    ~H"""
    <div class="space-y-4" data-testid="proposal-analysis">
      <.alert :if={!@current} color="gray" with_icon data-testid="proposal-analysis-stale">
        A tarefa não espera mais esta decisão.
      </.alert>
      <QuestionnaireComponents.questionnaire questionnaire={
        %{"diagnostico" => @result.diagnosis, "perguntas" => @result.questions}
      } />
      <.button
        link_type="live_redirect"
        to={~p"/w/#{@workspace.slug}/tasks/#{@result.task_id}"}
        variant="outline"
        icon="hero-arrow-right"
        data-testid="proposal-analysis-task"
      >
        Responder na tarefa
      </.button>
    </div>
    """
  end

  attr :result, :map, required: true
  attr :form, :any, required: true
  attr :task, :any, required: true
  attr :current, :boolean, required: true
  attr :may_cancel, :boolean, required: true

  defp decision_review(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="space-y-6">
        <.markdown_card
          id="proposal-diagnosis"
          icon="hero-magnifying-glass"
          title="Diagnóstico"
          markdown={@result.diagnosis}
          testid="proposal-diagnosis"
        />
        <.card variant="outline">
          <.card_content>
            <.section_heading
              icon={action_icon(@result.action)}
              title={"Recomendação: #{action_label(@result.action)}"}
              description={@task.decision_reason}
            />
            <.alert
              :if={!@current}
              color="warning"
              class="mb-4"
              data-testid="proposal-decision-stale"
            >
              A tarefa não espera mais esta decisão.
            </.alert>
            <.form for={@form} id="proposal-decision-form" phx-submit="apply_decision">
              <.icon_field
                :if={@result.choice}
                field={@form[:choice]}
                icon="hero-check-circle"
                label="Opção escolhida"
                data-testid="proposal-decision-choice"
              />
              <.markdown_editor
                id="proposal-decision-instructions"
                field={@form[:instructions]}
                label="Instruções para a próxima tentativa"
                icon="hero-chat-bubble-left-right"
                testid="proposal-decision-instructions"
                rows={6}
              />
              <div class="flex flex-wrap justify-end gap-2">
                <.button
                  :for={action <- ~w(cancel advance retry)}
                  type="submit"
                  name="action"
                  value={action}
                  icon={action_icon(action)}
                  variant={if action == @result.action, do: "solid", else: "outline"}
                  color={if action == "cancel", do: "danger", else: "primary"}
                  disabled={!@current or (action == "cancel" and !@may_cancel)}
                  data-testid={"proposal-decision-#{action}"}
                >
                  {action_label(action)}
                </.button>
              </div>
            </.form>
          </.card_content>
        </.card>
      </div>
      <div class="space-y-6">
        <.card variant="outline">
          <.card_content>
            <.section_heading icon="hero-arrows-right-left" title="Alternativas" />
            <p :if={@result.alternatives == []} class="text-sm text-gray-500 dark:text-gray-400">
              O agente não propôs outras.
            </p>
            <ul class="space-y-3" data-testid="proposal-alternatives">
              <li :for={alt <- @result.alternatives} class="text-sm">
                <p class="flex items-center gap-1.5 font-medium text-gray-900 dark:text-white">
                  <.icon name={action_icon(alt.action)} class="size-4 text-gray-400" />
                  {action_label(alt.action)}
                </p>
                <div class="mt-0.5 text-gray-600 dark:text-gray-300">
                  {Markdown.inline_html(alt.reason)}
                </div>
              </li>
            </ul>
          </.card_content>
        </.card>
      </div>
    </div>
    """
  end

  attr :result, :map, required: true
  attr :proposed, Pipeline, required: true, doc: "the revised pipeline, to draw"
  attr :current, Pipeline, default: nil, doc: "the pipeline as it is, to compare"
  attr :form, :any, required: true
  attr :project, :any, required: true
  attr :input, :map, required: true
  attr :job, :any, required: true
  attr :workspace, :any, required: true

  defp improve_review(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="grid gap-6 xl:grid-cols-2">
        <.markdown_card
          id="proposal-analysis"
          icon="hero-chart-bar"
          title="O que o histórico mostra"
          markdown={@result.analysis}
          testid="proposal-analysis"
        />
        <.card variant="outline">
          <.card_content>
            <.section_heading icon="hero-pencil-square" title="Mudanças propostas" />
            <ul class="space-y-3" data-testid="proposal-changes">
              <li :for={change <- @result.changes} class="text-sm">
                <p class="font-medium text-gray-900 dark:text-white">{change.where}</p>
                <div class="text-gray-700 dark:text-gray-200">
                  {Markdown.inline_html(change.what)}
                </div>
                <div class="text-xs text-gray-500 dark:text-gray-400">
                  {Markdown.inline_html(change.why)}
                </div>
              </li>
            </ul>
          </.card_content>
        </.card>
      </div>
      <.card variant="outline">
        <.card_content>
          <.section_heading
            icon="hero-squares-2x2"
            title={"Pipeline revisado: #{@result.pipeline["name"]}"}
          />
          <.live_component
            module={PipelineExplorer}
            id="proposal-explorer"
            pipeline={@proposed}
            opts={compare(@current)}
            testid="proposal"
          />
          <div class="mt-5 flex justify-end">
            <.button
              link_type="live_redirect"
              to={~p"/w/#{@workspace.slug}/pipelines/#{@result.pipeline_id}/edit?proposta=#{@job.id}"}
              icon="hero-arrow-right-circle"
              data-testid="proposal-review-pipeline"
            >
              Revisar e salvar o pipeline
            </.button>
          </div>
        </.card_content>
      </.card>

      <.card variant="outline">
        <.card_content>
          <.section_heading
            icon="hero-light-bulb"
            title="Notas do projeto revisadas"
            description="O que todo agente do pipeline lê sobre o projeto ({{projeto.notas}})."
          />
          <.alert :if={!@project} color="warning" class="mb-4" data-testid="proposal-notes-no-project">
            {@input["directory"]} ainda não tem projeto: crie um em Projetos para guardar as notas.
          </.alert>
          <.form :if={@project} for={@form} id="proposal-notes-form" phx-submit="save_notes">
            <.markdown_editor
              id="proposal-notes"
              field={@form[:notes]}
              label="Notas para os agentes"
              icon="hero-light-bulb"
              testid="proposal-notes"
              rows={8}
            />
            <div class="flex justify-end">
              <.button type="submit" icon="hero-check" data-testid="proposal-save-notes">
                Salvar notas
              </.button>
            </div>
          </.form>
        </.card_content>
      </.card>
    </div>
    """
  end
end
