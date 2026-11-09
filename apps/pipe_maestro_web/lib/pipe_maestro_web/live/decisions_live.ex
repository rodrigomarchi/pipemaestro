defmodule PipeMaestroWeb.DecisionsLive do
  @moduledoc """
  Everything in the workspace that waits for a person: each task paused for a
  decision, with the stage, the reason, the questionnaire of its pause
  (`PipeMaestroWeb.QuestionnaireLive`) or the analysis of its failure while
  it runs, and the manual decision (retry the stage or move on, optionally
  with instructions, or cancel the task). Updated live.
  """
  use PipeMaestroWeb, :live_view

  import PipeMaestroWeb.RunnerComponents, only: [time_ago: 2]
  import PipeMaestroWeb.QuestionnaireComponents, only: [analysis_state: 1, decode_answers: 1]
  import PipeMaestroWeb.TaskComponents, only: [task_progress: 1]

  alias PipeMaestro.{Tasks, Workspaces}
  alias PipeMaestro.Tasks.Task
  alias PipeMaestroWeb.{Markdown, ProposalRequest, QuestionnaireLive}

  @impl true
  def mount(_params, _session, socket) do
    workspace = socket.assigns.current_scope.workspace
    if connected?(socket), do: Tasks.subscribe({:workspace, workspace.id})

    {:ok,
     socket
     |> assign(page_title: "Decisões", mine: false, members: Workspaces.list_members(workspace))
     |> load()}
  end

  @impl true
  def handle_info({:task_updated, _task}, socket), do: {:noreply, load(socket)}

  @impl true
  # An option button sends the choice without an action: it retries the stage.
  def handle_event("suggest_decision", %{"task_id" => task_id}, socket),
    do: {:noreply, ProposalRequest.suggest_decision(socket, task_id)}

  def handle_event("questionnaire", %{"task_id" => id, "action" => action} = params, socket) do
    task = Tasks.get_task!(socket.assigns.current_scope.workspace, id)
    user = socket.assigns.current_scope.user
    answers = decode_answers(params["answers"])

    result =
      case action do
        "answer" -> Tasks.answer(task, answers, nil, by: user)
        "advance" -> Tasks.advance(task, nil, by: user, answers: answers)
        "cancel" -> Tasks.cancel_task(task, by: user)
      end

    {:noreply, socket |> decided(task, result) |> load()}
  end

  def handle_event("decide", %{"choice" => _choice} = params, socket)
      when not is_map_key(params, "action"),
      do: handle_event("decide", Map.put(params, "action", "retry"), socket)

  def handle_event("decide", %{"task_id" => id, "action" => action} = params, socket) do
    task = Tasks.get_task!(socket.assigns.current_scope.workspace, id)
    instructions = get_in(params, ["decision", "instructions"])
    opts = [by: socket.assigns.current_scope.user, choice: params["choice"]]

    result =
      case action do
        "retry" -> Tasks.retry_stage(task, instructions, opts)
        "advance" -> Tasks.advance(task, instructions, opts)
        "cancel" -> Tasks.cancel_task(task, by: opts[:by])
      end

    {:noreply, socket |> decided(task, result) |> load()}
  end

  def handle_event("assign", %{"task_id" => id, "owner" => %{"user_id" => user_id}}, socket) do
    task = Tasks.get_task!(socket.assigns.current_scope.workspace, id)
    user = Enum.find(socket.assigns.members, &(&1.id == user_id))

    case user && Tasks.assign_decision(task, user) do
      {:ok, _task} ->
        {:noreply, socket |> put_flash(:info, "Decisão passada para #{user.name}.") |> load()}

      _not_a_member ->
        {:noreply, put_flash(socket, :error, "Escolha alguém do workspace.")}
    end
  end

  def handle_event("filter", %{"mine" => mine}, socket),
    do: {:noreply, socket |> assign(mine: mine == "true") |> load()}

  defp decided(socket, task, result) do
    case result do
      {:ok, _task} -> put_flash(socket, :info, "Decisão registrada: #{task.title}.")
      {:error, :invalid_answers, reason} -> put_flash(socket, :error, reason)
      {:error, _reason} -> put_flash(socket, :error, "Essa tarefa não espera mais decisão.")
    end
  end

  defp load(socket) do
    user = socket.assigns.current_scope.user
    tasks = Tasks.list_awaiting(socket.assigns.current_scope.workspace)

    tasks =
      if socket.assigns.mine,
        do: Enum.filter(tasks, &(&1.decision_owner_id == user.id)),
        else: tasks

    assign(socket,
      tasks: tasks,
      options: Map.new(tasks, &{&1.id, Tasks.options(&1)}),
      questionnaires: Map.new(tasks, &{&1.id, Tasks.questionnaire(&1)}),
      now: DateTime.utc_now()
    )
  end

  # "em 23 h" while there is time; "atrasada há 2 h" past it.
  defp due_label(nil, _now), do: "sem prazo"

  defp due_label(due, now) do
    minutes = DateTime.diff(due, now, :minute)

    cond do
      minutes >= 60 -> "em #{div(minutes, 60)} h"
      minutes >= 0 -> "em #{minutes} min"
      minutes > -60 -> "atrasada há #{-minutes} min"
      true -> "atrasada há #{div(-minutes, 60)} h"
    end
  end

  defp overdue?(%Task{decision_due_at: nil}, _now), do: false
  defp overdue?(%Task{decision_due_at: due}, now), do: DateTime.compare(due, now) == :lt

  # The agent is analysing a failure on the page: it gets the room.
  defp analysing?(questionnaires),
    do: Enum.any?(questionnaires, fn {_id, q} -> q.analysis == :running end)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      pending_decisions={@pending_decisions}
      notification_center={@notification_center}
      current_scope={@current_scope}
      workspaces={@workspaces}
      active={:decisions}
      focus={analysing?(@questionnaires)}
      title="Decisões"
    >
      <.filter_bar>
        <.tabs variant="segmented">
          <.tab
            link_type="button"
            variant="segmented"
            is_active={not @mine}
            phx-click="filter"
            phx-value-mine="false"
            data-testid="decisions-all"
          >
            Todas
          </.tab>
          <.tab
            link_type="button"
            variant="segmented"
            is_active={@mine}
            phx-click="filter"
            phx-value-mine="true"
            data-testid="decisions-mine"
          >
            Só as minhas
          </.tab>
        </.tabs>
      </.filter_bar>

      <.record_list id="decisions" testid="decisions" empty={@tasks == []}>
        <.record_card
          :for={task <- @tasks}
          id={"decision-#{task.id}"}
          testid={"decision-#{task.id}"}
          tone={:awaiting}
        >
          <:leading><.record_icon icon="hero-hand-raised" color="warning" /></:leading>
          <:title>
            <.link
              navigate={~p"/w/#{@current_scope.workspace.slug}/tasks/#{task.id}"}
              class="no-underline hover:underline"
              data-testid={"decision-link-#{task.id}"}
            >
              {task.title}
            </.link>
          </:title>
          <:meta>
            <.record_fact icon="hero-squares-2x2" title="Pipeline">{task.pipeline_name}</.record_fact>
            <.record_fact icon="hero-folder" title="Projeto" testid={"decision-project-#{task.id}"}>
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
              testid={"decision-progress-#{task.id}"}
            />
            <.record_metric icon="hero-clock" title="Esperando desde">
              esperando {time_ago(task.updated_at, @now)}
            </.record_metric>
            <span class="inline-flex items-center gap-1">
              <.icon name="hero-bell-alert" class="size-3.5 text-gray-400 dark:text-gray-500" />
              <span
                class={overdue?(task, @now) && "font-medium text-danger-600 dark:text-danger-400"}
                data-testid={"decision-due-#{task.id}"}
              >
                {due_label(task.decision_due_at, @now)}
              </span>
            </span>
          </:aside>
          <:body interactive>
            <.form
              for={to_form(%{"user_id" => task.decision_owner_id}, as: "owner")}
              id={"decision-owner-form-#{task.id}"}
              phx-change="assign"
              class="mt-2 max-w-xs"
              data-testid={"decision-owner-form-#{task.id}"}
            >
              <input type="hidden" name="task_id" value={task.id} />
              <.icon_field
                field={to_form(%{"user_id" => task.decision_owner_id}, as: "owner")[:user_id]}
                icon="hero-user-circle"
                id={"decision-owner-#{task.id}"}
                type="select"
                label="Quem decide"
                options={Enum.map(@members, &{&1.name, &1.id})}
                data-testid={"decision-owner-#{task.id}"}
              />
            </.form>

            <.alert color="warning" with_icon class="mt-3">
              {Markdown.inline_html(task.decision_reason)}
            </.alert>
            <.analysis_state analysis={@questionnaires[task.id].analysis} key={task.id} />
            <.live_component
              :if={@questionnaires[task.id].questionnaire}
              module={QuestionnaireLive}
              id={"questionnaire-#{task.id}"}
              task_id={task.id}
              key={task.id}
              questionnaire={@questionnaires[task.id].questionnaire}
              can_cancel={can?(@current_scope, :cancel_task, task)}
            />
            <div class="mt-2 flex justify-end">
              <.button
                type="button"
                size="sm"
                variant="outline"
                icon="hero-cpu-chip"
                phx-click="suggest_decision"
                phx-value-task_id={task.id}
                data-testid={"decision-suggest-#{task.id}"}
              >
                Sugerir com IA
              </.button>
            </div>

            <.form
              for={to_form(%{}, as: "decision")}
              phx-submit="decide"
              class="mt-3"
              data-testid={"decision-form-#{task.id}"}
            >
              <input type="hidden" name="task_id" value={task.id} />
              <div :if={@options[task.id] != []} class="mb-3 flex flex-wrap items-center gap-2">
                <span class="text-sm text-gray-600 dark:text-gray-300">O agente propôs:</span>
                <.button
                  :for={{option, index} <- Enum.with_index(@options[task.id])}
                  type="submit"
                  name="choice"
                  value={option}
                  size="sm"
                  variant="outline"
                  data-testid={"decision-option-#{task.id}-#{index}"}
                >
                  {option}
                </.button>
              </div>
              <.markdown_editor
                id={"decision-editor-#{task.id}"}
                field={to_form(%{}, as: "decision")[:instructions]}
                input_id={"decision-instructions-#{task.id}"}
                label="Instruções para continuar (opcional)"
                icon="hero-chat-bubble-left-right"
                rows={2}
                testid={"decision-instructions-#{task.id}"}
              />
              <div class="flex flex-wrap justify-end gap-2">
                <.button
                  type="submit"
                  name="action"
                  value="cancel"
                  variant="ghost"
                  color="danger"
                  data-testid={"decision-cancel-#{task.id}"}
                >
                  Cancelar tarefa
                </.button>
                <.button
                  type="submit"
                  name="action"
                  value="retry"
                  variant="outline"
                  icon="hero-arrow-path"
                  data-testid={"decision-retry-#{task.id}"}
                >
                  Refazer etapa
                </.button>
                <.button
                  type="submit"
                  name="action"
                  value="advance"
                  icon="hero-forward"
                  data-testid={"decision-advance-#{task.id}"}
                >
                  Seguir para a próxima
                </.button>
              </div>
            </.form>
          </:body>
        </.record_card>
        <:empty_state>
          <.record_empty
            testid="no-decisions"
            icon="hero-check-circle"
            title="Nenhuma decisão pendente"
            description="Quando uma etapa pedir ajuda, esgotar as tentativas ou estourar o orçamento, a tarefa aparece aqui."
          />
        </:empty_state>
      </.record_list>
    </Layouts.app>
    """
  end
end
