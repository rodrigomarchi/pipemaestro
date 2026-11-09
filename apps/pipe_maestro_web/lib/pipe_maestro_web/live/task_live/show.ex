defmodule PipeMaestroWeb.TaskLive.Show do
  @moduledoc """
  One task, as its pipeline (`PipeMaestroWeb.TaskLive.PipelineView`): the
  page is the pipeline, top to bottom, and every place on it opens a drawer
  with what belongs there. The task is read light
  (`PipeMaestro.Tasks.get_task_overview!/2`): nothing a stage produced is in it.

  A stage opens in a panel (`PipeMaestroWeb.TaskLive.StagePanel`), kept in
  the URL as `?etapa=<key>`; the entry, the pull request, the end and the
  correction open in `PipeMaestroWeb.TaskLive.NodePanel`, as `?no=<place>`.
  The browser's back closes either. The stage panel reads the stage's
  attempts in full. While its stage runs, the page follows that stage's job
  only (`Jobs.subscribe({:job, id})`, and `Jobs.unsubscribe/1` when the panel
  closes or moves) and hands its events, what the agent is typing and what it
  spent so far (read at most every `@live_every` ms) to the panel. A task
  waiting for a decision shows a banner that opens the waiting stage, whose
  panel takes the decision (`PipeMaestroWeb.TaskLive.DecisionPanel`).

  This LiveView holds what is the task's: its actions and decisions, all
  taken by `PipeMaestro.Tasks`.
  """
  use PipeMaestroWeb, :live_view

  import PipeMaestroWeb.JobComponents, only: [format_cost: 1]
  import PipeMaestroWeb.QuestionnaireComponents, only: [decode_answers: 1]
  import PipeMaestroWeb.TaskComponents, only: [task_status: 1, merge_state: 1]

  alias Phoenix.Socket.Broadcast
  alias PipeMaestro.{Insights, Jobs, Tasks}
  alias PipeMaestro.Jobs.Files
  alias PipeMaestro.Tasks.Task
  alias PipeMaestroWeb.{ProposalRequest, RunnerStatus}
  alias PipeMaestroWeb.TaskLive.{NodePanel, PipelineView, StagePanel}

  @live_every 2_000
  @panel "stage-panel"

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    workspace = socket.assigns.current_scope.workspace
    task = Tasks.get_task_overview!(workspace, id)

    # Subscribe before reading again, so nothing in between is missed.
    task =
      if connected?(socket) do
        Tasks.subscribe({:task, task.id})
        RunnerStatus.subscribe(workspace.id)
        Tasks.get_task_overview!(workspace, id)
      else
        task
      end

    {:ok,
     socket
     |> assign(page_title: task.title, task: task, stage: nil, node: nil, node_tab: nil)
     |> assign(followed_job_id: nil, live_pending: false, redo: nil)
     |> assign(decision: to_form(%{"instructions" => ""}, as: "decision"))
     |> load_online()
     |> load_task_data()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(stage: stage_index(socket.assigns.task, params["etapa"]))
     |> open_node(NodePanel.chosen(socket.assigns.task, params["no"]))
     |> follow_job()}
  end

  # The index of the stage `key` in the task's snapshot; an unknown key opens nothing.
  defp stage_index(_task, nil), do: nil
  defp stage_index(%Task{stages: stages}, key), do: Enum.find_index(stages, &(&1.key == key))

  # A place opened anew shows its first tab.
  defp open_node(socket, node) do
    if node == socket.assigns.node,
      do: socket,
      else: assign(socket, node: node, node_tab: nil)
  end

  @impl true
  def handle_info(%Broadcast{event: "presence_diff"}, socket), do: {:noreply, load_online(socket)}
  def handle_info(:runners_changed, socket), do: {:noreply, load_online(socket)}

  def handle_info({:task_updated, %Task{} = task}, socket) do
    socket =
      if socket.assigns.task.status == :awaiting_decision and task.status != :awaiting_decision,
        do: put_flash(socket, :info, "Outra pessoa respondeu esta decisão."),
        else: socket

    {:noreply, refresh(socket)}
  end

  # The followed job's events and typing go to the stage's panel; any other
  # job's are dropped.
  def handle_info(
        {:job_event, %{job_id: id} = event},
        %{assigns: %{followed_job_id: id}} = socket
      )
      when not is_nil(id) do
    send_update(StagePanel, id: @panel, job_event: event)
    {:noreply, socket}
  end

  def handle_info({:job_event, _other_job}, socket), do: {:noreply, socket}

  def handle_info({:job_delta, id, text}, %{assigns: %{followed_job_id: id}} = socket)
      when not is_nil(id) do
    send_update(StagePanel, id: @panel, job_delta: {id, text})
    {:noreply, socket}
  end

  def handle_info({:job_delta, _other_job, _text}, socket), do: {:noreply, socket}

  # The followed job's telemetry comes in bursts: what it spent so far is read
  # again once per `@live_every`. The rest of it shows on the job's own page.
  def handle_info({:job_telemetry, id}, %{assigns: %{followed_job_id: id}} = socket)
      when not is_nil(id) do
    if not socket.assigns.live_pending,
      do: Process.send_after(self(), {:refresh_spent, id}, @live_every)

    {:noreply, assign(socket, live_pending: true)}
  end

  def handle_info({:job_telemetry, _other_job}, socket), do: {:noreply, socket}

  def handle_info({:refresh_spent, id}, %{assigns: %{followed_job_id: id}} = socket)
      when not is_nil(id) do
    job = Jobs.get_job!(socket.assigns.current_scope.workspace, id)
    send_update(StagePanel, id: @panel, spent: {id, Insights.live(job)})
    {:noreply, assign(socket, live_pending: false)}
  end

  def handle_info({:refresh_spent, _other_job}, socket),
    do: {:noreply, assign(socket, live_pending: false)}

  # The job's end comes as the task's update.
  def handle_info({:job_updated, _job}, socket), do: {:noreply, socket}

  @impl true
  def handle_event("close_panel", _params, socket),
    do: {:noreply, push_patch(socket, to: stage_path(socket, nil))}

  def handle_event("select_tab", %{"tab" => tab}, socket),
    do: {:noreply, assign(socket, node_tab: tab)}

  # The form has one submit button per decision; the pressed one comes as
  # "action", with the instructions typed.
  # An option button sends the choice without an action: it retries the stage.
  def handle_event("questionnaire", %{"action" => "answer"} = params, socket),
    do:
      decide(
        socket,
        &Tasks.answer(&1, decode_answers(params["answers"]), nil,
          by: socket.assigns.current_scope.user
        ),
        "Respostas enviadas; a etapa roda de novo."
      )

  def handle_event("questionnaire", %{"action" => "advance"} = params, socket),
    do:
      decide(
        socket,
        &Tasks.advance(&1, nil,
          by: socket.assigns.current_scope.user,
          answers: decode_answers(params["answers"])
        ),
        "Seguindo para a próxima etapa."
      )

  def handle_event("questionnaire", %{"action" => "cancel"}, socket),
    do: handle_event("cancel", %{}, socket)

  def handle_event("suggest_decision", _params, socket),
    do: {:noreply, ProposalRequest.suggest_decision(socket, socket.assigns.task.id)}

  def handle_event("decide", %{"choice" => _choice} = params, socket)
      when not is_map_key(params, "action"),
      do: handle_event("decide", Map.put(params, "action", "retry"), socket)

  def handle_event("decide", %{"action" => "retry"} = params, socket),
    do:
      decide(
        socket,
        &Tasks.retry_stage(&1, instructions(params), decision_opts(socket, params)),
        "Etapa enviada de novo ao runner."
      )

  def handle_event("decide", %{"action" => "advance"} = params, socket),
    do:
      decide(
        socket,
        &Tasks.advance(&1, instructions(params), decision_opts(socket, params)),
        "Seguindo para a próxima etapa."
      )

  def handle_event("cancel", _params, socket) do
    if can?(socket.assigns.current_scope, :cancel_task, socket.assigns.task),
      do: cancel(socket),
      else:
        {:noreply, put_flash(socket, :error, "Você não pode cancelar a tarefa de outra pessoa.")}
  end

  def handle_event("rerun", _params, socket) do
    %{user: user, workspace: workspace} = socket.assigns.current_scope

    case Tasks.rerun(user, socket.assigns.task) do
      {:ok, task} ->
        {:noreply,
         socket
         |> put_flash(:info, "Tarefa iniciada de novo em #{task.runner.name}.")
         |> push_navigate(to: ~p"/w/#{workspace.slug}/tasks/#{task.id}")}

      {:error, _changeset} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Não foi possível reexecutar: o pipeline, o runner ou o diretório não estão mais disponíveis. Use Duplicar."
         )}
    end
  end

  def handle_event("instruct", %{"instruct" => %{"text" => text}}, socket) do
    case Tasks.instruct(socket.assigns.task, text) do
      {:ok, _task} ->
        {:noreply, socket |> refresh() |> put_flash(:info, "Mensagem guardada.")}

      {:error, :blank} ->
        {:noreply, socket}

      {:error, :finished} ->
        {:noreply, put_flash(socket, :error, "A tarefa já terminou.")}
    end
  end

  def handle_event("request_pause", _params, socket) do
    case Tasks.request_pause(socket.assigns.task) do
      {:ok, _task} ->
        {:noreply, refresh(socket)}

      {:error, :not_running} ->
        {:noreply, put_flash(socket, :error, "A tarefa não está rodando.")}
    end
  end

  def handle_event("open_redo", %{"index" => index}, socket),
    do: {:noreply, assign(socket, redo: String.to_integer(index))}

  def handle_event("close_redo", _params, socket), do: {:noreply, assign(socket, redo: nil)}

  def handle_event("redo", %{"redo" => params}, socket) do
    socket.assigns.task
    |> Tasks.redo_from(socket.assigns.redo, params["instructions"], rerun_opts(socket, params))
    |> rerun_result(socket, "A etapa vai rodar de novo.")
  end

  def handle_event("correct", %{"correct" => params}, socket) do
    socket.assigns.task
    |> Tasks.correct(params["prompt"], rerun_opts(socket, params))
    |> rerun_result(socket, "A correção vai rodar como uma nova etapa.")
  end

  def handle_event("interrupt", _params, socket) do
    case Tasks.interrupt(socket.assigns.task, stop_opts(socket)) do
      {:ok, _task} ->
        {:noreply,
         socket
         |> refresh()
         |> put_flash(:info, "Interrupção pedida: a tarefa vai aguardar uma decisão.")}

      {:error, :not_running} ->
        {:noreply, put_flash(socket, :error, "A tarefa não está rodando.")}
    end
  end

  def handle_event("retry_merge", _params, socket) do
    case Tasks.retry_merge(socket.assigns.task, socket.assigns.current_scope.user) do
      {:ok, _task} ->
        {:noreply,
         socket
         |> refresh()
         |> put_flash(:info, "A plataforma vai esperar os checks e tentar o merge de novo.")}

      {:error, :not_blocked} ->
        {:noreply, put_flash(socket, :error, "O merge desta tarefa não está parado.")}
    end
  end

  def handle_event("remove_worktree", _params, socket) do
    case Tasks.remove_worktree(socket.assigns.task) do
      {:ok, _task} ->
        {:noreply, put_flash(socket, :info, "Pedido de remoção enviado ao runner.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Não há worktree para remover.")}
    end
  end

  defp instructions(params), do: get_in(params, ["decision", "instructions"])

  defp cancel(socket) do
    case Tasks.cancel_task(socket.assigns.task, stop_opts(socket)) do
      {:ok, _task} ->
        {:noreply, socket |> refresh() |> put_flash(:info, "Cancelamento pedido.")}

      {:error, :finished} ->
        {:noreply, put_flash(socket, :error, "A tarefa já terminou.")}
    end
  end

  # A runner offline cannot confirm a stop: the job ends without it.
  defp stop_opts(socket) do
    [
      by: socket.assigns.current_scope.user,
      runner_online?: not Tasks.runner_offline?(socket.assigns.task, socket.assigns.online)
    ]
  end

  defp rerun_opts(socket, params),
    do: [by: socket.assigns.current_scope.user, runner_id: params["runner_id"]]

  defp rerun_result({:ok, _task}, socket, message),
    do: {:noreply, socket |> assign(redo: nil) |> refresh() |> put_flash(:info, message)}

  defp rerun_result({:error, reason}, socket, _message),
    do: {:noreply, put_flash(socket, :error, rerun_error(reason))}

  defp rerun_error(:running), do: "A tarefa está rodando."
  defp rerun_error(:active), do: "A tarefa ainda não terminou: decida a pausa ou cancele antes."
  defp rerun_error(:no_stage), do: "Essa etapa não existe."
  defp rerun_error(:blank), do: "Escreva o que a correção deve fazer."
  defp rerun_error(:removing), do: "O worktree está sendo removido: aguarde o runner terminar."

  defp rerun_error(:runner),
    do: "Esse runner não pode continuar a tarefa: a branch dela não está no origin."

  defp decision_opts(socket, params),
    do: [by: socket.assigns.current_scope.user, choice: params["choice"]]

  defp decide(socket, fun, message) do
    case fun.(socket.assigns.task) do
      {:ok, _task} ->
        {:noreply,
         socket
         |> assign(decision: to_form(%{"instructions" => ""}, as: "decision"))
         |> refresh()
         |> put_flash(:info, message)}

      {:error, :not_awaiting} ->
        {:noreply, put_flash(socket, :error, "A tarefa não está aguardando uma decisão.")}

      {:error, :invalid_answers, reason} ->
        {:noreply, put_flash(socket, :error, reason)}
    end
  end

  # The task read again, light, with what the page shows of it, and the job to follow.
  defp refresh(socket) do
    task =
      Tasks.get_task_overview!(socket.assigns.current_scope.workspace, socket.assigns.task.id)

    socket
    |> assign(task: task)
    |> load_task_data()
    |> follow_job()
    |> close_gone_node()
  end

  # A place the task no longer has (the correction, once it runs) closes.
  defp close_gone_node(%{assigns: %{node: nil}} = socket), do: socket

  defp close_gone_node(socket) do
    if NodePanel.chosen(socket.assigns.task, socket.assigns.node),
      do: socket,
      else: socket |> assign(node: nil) |> push_patch(to: stage_path(socket, nil))
  end

  defp load_task_data(socket) do
    task = socket.assigns.task
    choices = if task.status == :running, do: [], else: Tasks.runner_choices(task)
    prompt = if PipelineView.no_pr?(task), do: "Abra o PR desta branch.", else: ""

    assign(socket,
      decisions: Tasks.list_decisions(task),
      options: Tasks.options(task),
      questionnaire: Tasks.questionnaire(task),
      cost: Tasks.cost(task),
      changed_files: Tasks.changed_files(task),
      files: Files.list_for_task(task),
      runner_choices: choices,
      correct_form: to_form(%{"prompt" => prompt, "runner_id" => task.runner_id}, as: "correct"),
      redo_form: to_form(%{"instructions" => "", "runner_id" => task.runner_id}, as: "redo")
    )
  end

  # The job of the open stage's attempt running now is the one followed; the
  # previous one is let go.
  defp follow_job(socket) do
    job_id = running_job_id(socket.assigns.task, socket.assigns.stage)
    previous = socket.assigns.followed_job_id

    if job_id != previous and connected?(socket) do
      if previous, do: Jobs.unsubscribe({:job, previous})
      if job_id, do: Jobs.subscribe({:job, job_id})
    end

    assign(socket, followed_job_id: job_id)
  end

  defp running_job_id(_task, nil), do: nil

  defp running_job_id(%Task{stage_runs: runs}, index) do
    case runs |> Enum.filter(&(&1.index == index)) |> List.last() do
      %{status: :running, job: %{id: id}} -> id
      _ended_or_none -> nil
    end
  end

  # What tells the panel its stage changed: its attempts, their status and their jobs'.
  defp fingerprint(%Task{stage_runs: runs}, index) do
    for run <- runs, run.index == index do
      {run.id, run.status, run.updated_at, run.job && {run.job.status, run.job.updated_at}}
    end
  end

  defp stage_path(socket, key),
    do:
      PipelineView.stage_path(
        socket.assigns.current_scope.workspace.slug,
        socket.assigns.task,
        key
      )

  defp stage_name(%Task{stages: stages}, index) do
    case Enum.at(stages, index) do
      nil -> "—"
      stage -> stage.name
    end
  end

  defp redoable?(%Task{} = task), do: task.status != :running

  defp removable_worktree?(%Task{} = task) do
    not Task.active?(task) and not is_nil(task.worktree) and is_nil(task.worktree_removed_at) and
      is_nil(task.worktree_removal_requested_at)
  end

  # The workspace's runners online now: a running task on any other is stuck.
  defp load_online(socket),
    do: assign(socket, online: RunnerStatus.online_ids(socket.assigns.current_scope.workspace.id))

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
      focus={Task.active?(@task)}
      title={@task.title}
      back={
        %{
          to: ~p"/w/#{@current_scope.workspace.slug}/tasks",
          label: "Tarefas",
          testid: "back-to-tasks"
        }
      }
    >
      <:status>
        <.task_status task={@task} data-testid="task-status" />
        <.merge_state
          :if={@task.merge_state}
          task={@task}
          title={@task.merge_reason}
          data-testid="task-merge-state"
        />
        <.badge
          size="sm"
          variant="outline"
          color="gray"
          label={format_cost(@cost)}
          data-testid="task-cost-badge"
        />
      </:status>
      <:action
        :if={!Task.active?(@task)}
        label="Reexecutar"
        icon="hero-arrow-path"
        on_click="rerun"
        testid="task-rerun"
      />
      <:action
        :if={@task.merge_state == "blocked" and @task.status == :succeeded}
        label="Tentar o merge de novo"
        icon="hero-arrows-pointing-in"
        on_click="retry_merge"
        testid="task-merge-retry"
      />
      <:action
        label="Duplicar"
        icon="hero-document-duplicate"
        navigate={~p"/w/#{@current_scope.workspace.slug}/tasks?duplicate=#{@task.id}"}
        testid="task-duplicate"
      />
      <:action
        :if={removable_worktree?(@task)}
        label="Remover worktree"
        icon="hero-trash"
        on_click="remove_worktree"
        confirm="Remover o worktree desta tarefa? O branch continua no repositório; o que não foi commitado se perde."
        testid="task-remove-worktree"
      />
      <:action
        :if={Task.active?(@task) and can?(@current_scope, :cancel_task, @task)}
        label="Cancelar"
        icon="hero-stop"
        on_click="cancel"
        confirm="Cancelar esta tarefa?"
        danger
        testid="task-cancel"
      />

      <div class="space-y-4">
        <PipelineView.decision_banner task={@task} slug={@current_scope.workspace.slug} />
        <PipelineView.runner_alerts task={@task} online={@online} />
        <.card variant="outline">
          <.card_content>
            <PipelineView.overview
              task={@task}
              slug={@current_scope.workspace.slug}
              decisions={@decisions}
              files={@files}
              changed_files={@changed_files}
              cost={@cost}
              open={@node}
            />
          </.card_content>
        </.card>

        <NodePanel.node_panel
          :if={@node}
          node={@node}
          tab={@node_tab}
          task={@task}
          slug={@current_scope.workspace.slug}
          cost={@cost}
          files={@files}
          changed_files={@changed_files}
          online={@online}
          correct_form={@correct_form}
          runner_choices={@runner_choices}
        />

        <.live_component
          :if={@stage}
          module={StagePanel}
          id="stage-panel"
          task={@task}
          index={@stage}
          fingerprint={fingerprint(@task, @stage)}
          live_job_id={@followed_job_id}
          files={@files}
          slug={@current_scope.workspace.slug}
          quota_bytes={Files.quota_bytes(@current_scope.workspace)}
          redoable={redoable?(@task)}
          questionnaire={@questionnaire}
          options={@options}
          decision={@decision}
          can_cancel={can?(@current_scope, :cancel_task, @task)}
        />

        <.modal
          :if={@redo}
          id="redo-modal"
          title={"Refazer a partir de \"#{stage_name(@task, @redo)}\""}
          max_width="lg"
          on_cancel={JS.push("close_redo")}
        >
          <.form for={@redo_form} id="redo-form" phx-submit="redo" data-testid="stage-redo-modal">
            <p class="mb-3 text-sm text-gray-600 dark:text-gray-300">
              Esta etapa roda de novo, e as seguintes também.
            </p>
            <.markdown_editor
              id="stage-redo-text"
              field={@redo_form[:instructions]}
              label="Instruções (opcional)"
              icon="hero-chat-bubble-bottom-center-text"
              rows={3}
              placeholder="Ex.: desta vez, escreva os testes antes."
              testid="stage-redo-text"
            />
            <PipelineView.rerun_runner
              form={@redo_form}
              runners={@runner_choices}
              online={@online}
              testid="stage-redo-runner"
            />
            <div class="flex flex-wrap justify-end gap-2">
              <.button type="button" variant="ghost" color="gray" phx-click="close_redo">
                Cancelar
              </.button>
              <.button type="submit" icon="hero-arrow-uturn-left" data-testid="stage-redo-submit">
                Refazer
              </.button>
            </div>
          </.form>
        </.modal>
      </div>
    </Layouts.app>
    """
  end
end
