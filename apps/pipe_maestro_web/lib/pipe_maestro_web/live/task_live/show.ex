defmodule PipeMaestroWeb.TaskLive.Show do
  @moduledoc """
  One task, read as one pipeline from top to bottom: each stage's title and,
  right under it, what its attempts produced (summary, the agent's final
  answer, the artifact). The stage running now shows the agent's steps live,
  a stream of timeline segments whose last strip grows in place; a finished
  attempt's steps open on demand, filtered here, and what it spent so far
  (`PipeMaestro.Insights.live/1`) follows the CLI's telemetry, at most every
  `@live_every` ms. When the task waits for a decision, the decision panel sits
  under the stage that waits: the questionnaire of the pause, if any
  (`PipeMaestroWeb.QuestionnaireLive`), or the analysis of a failure while it
  runs, and the manual decision, folded away while there is something to
  answer.
  """
  use PipeMaestroWeb, :live_view

  alias PipeMaestroWeb.IntegrationComponents

  import PipeMaestroWeb.JobComponents,
    only: [
      steps: 1,
      timeline_items: 2,
      timeline_push: 2,
      timeline_segment: 1,
      timeline_tail: 1,
      typing: 1,
      format_cost: 1,
      format_duration: 1,
      format_percent: 1,
      short_number: 1
    ]

  import PipeMaestroWeb.TaskComponents

  import PipeMaestroWeb.QuestionnaireComponents,
    only: [analysis_state: 1, answer_list: 1, decode_answers: 1]

  alias Phoenix.Socket.Broadcast
  alias PipeMaestro.{Insights, Jobs, Tasks}
  alias PipeMaestro.Jobs.Job
  alias PipeMaestro.Tasks.{StageRun, Task}
  alias PipeMaestroWeb.{Markdown, ProposalRequest, QuestionnaireLive, RunnerStatus}

  @live_every 2_000

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    workspace = socket.assigns.current_scope.workspace
    task = Tasks.get_task!(workspace, id)

    # Subscribe before reading again, so nothing in between is missed.
    task =
      if connected?(socket) do
        Tasks.subscribe({:task, task.id})
        RunnerStatus.subscribe(workspace.id)
        Tasks.get_task!(workspace, id)
      else
        task
      end

    {:ok,
     socket
     |> assign(page_title: task.title, task: task, live_job_id: nil, timelines: %{})
     |> assign(live_spent: nil, live_pending: false)
     |> assign(raw_artifacts: MapSet.new(), typing: nil, step_filters: %{})
     |> load_online()
     |> load_decisions()
     |> assign(decision: to_form(%{"instructions" => ""}, as: "decision"))
     |> assign(redo: nil)
     |> load_rerun()
     |> follow_running_job()}
  end

  @impl true
  def handle_info(%Broadcast{event: "presence_diff"}, socket), do: {:noreply, load_online(socket)}
  def handle_info(:runners_changed, socket), do: {:noreply, load_online(socket)}

  def handle_info({:task_updated, %Task{} = task}, socket) do
    socket =
      if socket.assigns.task.status == :awaiting_decision and task.status != :awaiting_decision,
        do: put_flash(socket, :info, "Outra pessoa respondeu esta decisão."),
        else: socket

    {:noreply,
     socket |> assign(task: task) |> load_decisions() |> load_rerun() |> follow_running_job()}
  end

  # The running job's telemetry comes in bursts: what it spent so far is read
  # again once per `@live_every`. The rest of it shows on the job's own page.
  def handle_info({:job_telemetry, job_id}, %{assigns: %{live_job_id: job_id}} = socket)
      when not is_nil(job_id) do
    if not socket.assigns.live_pending,
      do: Process.send_after(self(), {:refresh_spent, job_id}, @live_every)

    {:noreply, assign(socket, live_pending: true)}
  end

  def handle_info({:job_telemetry, _job_id}, socket), do: {:noreply, socket}

  def handle_info({:refresh_spent, job_id}, %{assigns: %{live_job_id: job_id}} = socket) do
    job = Jobs.get_job!(socket.assigns.current_scope.workspace, job_id)
    {:noreply, assign(socket, live_spent: Insights.live(job), live_pending: false)}
  end

  def handle_info({:refresh_spent, _job_id}, socket),
    do: {:noreply, assign(socket, live_pending: false)}

  def handle_info({:job_event, event}, socket) do
    with true <- event.job_id == socket.assigns.live_job_id,
         {segment, tail} when segment != :seen <-
           timeline_push(socket.assigns.timeline_tail, event) do
      {:noreply,
       socket
       |> stream_insert(:timeline, segment)
       |> assign(timeline_tail: tail, typing: nil)}
    else
      _other_job_or_seen -> {:noreply, socket}
    end
  end

  def handle_info({:job_delta, job_id, text}, socket) do
    if job_id == socket.assigns.live_job_id,
      do: {:noreply, assign(socket, typing: text)},
      else: {:noreply, socket}
  end

  def handle_info({:job_updated, _job}, socket), do: {:noreply, socket}

  @impl true
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
      {:ok, task} ->
        {:noreply, socket |> assign(task: task) |> put_flash(:info, "Mensagem guardada.")}

      {:error, :blank} ->
        {:noreply, socket}

      {:error, :finished} ->
        {:noreply, put_flash(socket, :error, "A tarefa já terminou.")}
    end
  end

  def handle_event("request_pause", _params, socket) do
    case Tasks.request_pause(socket.assigns.task) do
      {:ok, task} ->
        {:noreply, assign(socket, task: task)}

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
      {:ok, task} ->
        {:noreply,
         socket
         |> assign(task: task)
         |> put_flash(:info, "Interrupção pedida: a tarefa vai aguardar uma decisão.")}

      {:error, :not_running} ->
        {:noreply, put_flash(socket, :error, "A tarefa não está rodando.")}
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

  # An artifact shows rendered; this flips one between that and its text.
  def handle_event("toggle_artifact", %{"run" => run_id}, socket) do
    raw = socket.assigns.raw_artifacts

    raw =
      if MapSet.member?(raw, run_id),
        do: MapSet.delete(raw, run_id),
        else: MapSet.put(raw, run_id)

    {:noreply, assign(socket, raw_artifacts: raw)}
  end

  # A finished attempt's steps are read only when someone opens them.
  def handle_event("toggle_steps", %{"job" => job_id}, socket) do
    timelines =
      if Map.has_key?(socket.assigns.timelines, job_id) do
        Map.delete(socket.assigns.timelines, job_id)
      else
        job =
          Enum.find_value(socket.assigns.task.stage_runs, fn run ->
            run.job && run.job.id == job_id && run.job
          end)

        if job,
          do: Map.put(socket.assigns.timelines, job_id, Jobs.list_events(job)),
          else: socket.assigns.timelines
      end

    {:noreply, assign(socket, timelines: timelines)}
  end

  def handle_event("filter_steps", %{"job" => job_id, "filter" => filter}, socket)
      when filter in ~w(all agent tools thinking errors),
      do: {:noreply, update(socket, :step_filters, &Map.put(&1, job_id, filter))}

  defp instructions(params), do: get_in(params, ["decision", "instructions"])

  defp cancel(socket) do
    case Tasks.cancel_task(socket.assigns.task, stop_opts(socket)) do
      {:ok, task} ->
        {:noreply, socket |> assign(task: task) |> put_flash(:info, "Cancelamento pedido.")}

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

  defp rerun_result({:ok, task}, socket, message) do
    {:noreply,
     socket
     |> assign(task: task, redo: nil)
     |> load_decisions()
     |> load_rerun()
     |> put_flash(:info, message)
     |> follow_running_job()}
  end

  defp rerun_result({:error, reason}, socket, _message),
    do: {:noreply, put_flash(socket, :error, rerun_error(reason))}

  defp rerun_error(:running), do: "A tarefa está rodando."
  defp rerun_error(:active), do: "A tarefa ainda não terminou: decida a pausa ou cancele antes."
  defp rerun_error(:no_stage), do: "Essa etapa não existe."
  defp rerun_error(:blank), do: "Escreva o que a correção deve fazer."
  defp rerun_error(:removing), do: "O worktree está sendo removido: aguarde o runner terminar."

  defp rerun_error(:runner),
    do: "Esse runner não pode continuar a tarefa: a branch dela não está no origin."

  # Where a stage can run again by hand, and the runners offered for it.
  defp load_rerun(socket) do
    task = socket.assigns.task

    choices = if task.status == :running, do: [], else: Tasks.runner_choices(task)
    prompt = if no_pr?(task), do: "Abra o PR desta branch.", else: ""

    assign(socket,
      runner_choices: choices,
      correct_form: to_form(%{"prompt" => prompt, "runner_id" => task.runner_id}, as: "correct"),
      redo_form: to_form(%{"instructions" => "", "runner_id" => task.runner_id}, as: "redo")
    )
  end

  # A task that delivers pull requests ended without one.
  defp no_pr?(%Task{} = task) do
    task.status == :succeeded and task.git and is_nil(task.pr_url) and
      match?(%{"delivery" => "pr"}, task.pipeline_context)
  end

  defp runner_options(runners, online) do
    for runner <- runners do
      {if(MapSet.member?(online, runner.id), do: runner.name, else: "#{runner.name} (offline)"),
       runner.id}
    end
  end

  defp decision_opts(socket, params),
    do: [by: socket.assigns.current_scope.user, choice: params["choice"]]

  defp decide(socket, fun, message) do
    case fun.(socket.assigns.task) do
      {:ok, task} ->
        {:noreply,
         socket
         |> assign(task: task, decision: to_form(%{"instructions" => ""}, as: "decision"))
         |> load_decisions()
         |> put_flash(:info, message)
         |> follow_running_job()}

      {:error, :not_awaiting} ->
        {:noreply, put_flash(socket, :error, "A tarefa não está aguardando uma decisão.")}

      {:error, :invalid_answers, reason} ->
        {:noreply, put_flash(socket, :error, reason)}
    end
  end

  defp load_decisions(socket) do
    task = socket.assigns.task

    assign(socket,
      decisions: Tasks.list_decisions(task),
      options: Tasks.options(task),
      questionnaire: Tasks.questionnaire(task),
      cost: Tasks.cost(task)
    )
  end

  # The running attempt's steps stream in live, as segments of its timeline.
  defp follow_running_job(socket) do
    job =
      Enum.find_value(socket.assigns.task.stage_runs, fn run ->
        run.status == :running && run.job
      end)

    cond do
      is_nil(job) ->
        socket |> assign(live_job_id: nil, typing: nil, live_spent: nil) |> live_timeline([])

      job.id == socket.assigns.live_job_id ->
        socket

      true ->
        if connected?(socket), do: Jobs.subscribe({:job, job.id})

        socket
        |> assign(live_job_id: job.id, typing: nil, live_spent: Insights.live(job))
        |> live_timeline(Jobs.list_events(job))
    end
  end

  defp live_timeline(socket, events) do
    segments = timeline_items(events, "all")

    socket
    |> assign(timeline_tail: timeline_tail(segments))
    |> stream(:timeline, segments, reset: true)
  end

  # The pipeline as rows: every stage of the snapshot with its attempts and
  # where it stands.
  # The files changed since the task started, as of its latest stage report.
  defp task_files(%Task{stage_runs: runs}) do
    runs
    |> Enum.reverse()
    |> Enum.find_value([], fn run ->
      run.job && run.job.changes && run.job.changes["task_files"]
    end)
  end

  defp decision_label(:retry), do: "Refazer"
  defp decision_label(:advance), do: "Seguir"
  defp decision_label(:cancel), do: "Cancelar"
  defp decision_label(:correct), do: "Corrigir"

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

  defp worktree_state(%Task{worktree_removed_at: %DateTime{}}), do: "Removido do runner."

  defp worktree_state(%Task{worktree_removal_requested_at: %DateTime{}}),
    do: "Removendo: aguardando o runner."

  defp worktree_state(%Task{worktree_error: error}) when is_binary(error),
    do: "Não foi possível remover: #{error}"

  defp worktree_state(_task), do: nil

  defp stage_rows(%Task{} = task) do
    runs_by_stage = Enum.group_by(task.stage_runs, & &1.index)

    task.stages
    |> Enum.with_index()
    |> Enum.map(fn {stage, index} ->
      runs = Map.get(runs_by_stage, index, [])
      %{index: index, stage: stage, runs: runs, state: stage_state(task, index, runs)}
    end)
  end

  defp stage_state(%Task{current_stage: index, status: :awaiting_decision}, index, _runs),
    do: :awaiting

  defp stage_state(_task, _index, []), do: :pending
  defp stage_state(_task, _index, runs), do: List.last(runs).status

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      pending_decisions={@pending_decisions}
      current_scope={@current_scope}
      workspaces={@workspaces}
      active={:tasks}
      title={@task.title}
    >
      <:actions>
        <.button
          link_type="live_redirect"
          to={~p"/w/#{@current_scope.workspace.slug}/tasks"}
          size="sm"
          variant="ghost"
          color="gray"
          icon="hero-arrow-left"
          data-testid="back-to-tasks"
        >
          Tarefas
        </.button>
        <.button
          :if={!Task.active?(@task)}
          size="sm"
          variant="outline"
          color="gray"
          icon="hero-arrow-path"
          phx-click="rerun"
          data-testid="task-rerun"
        >
          Reexecutar
        </.button>
        <.button
          size="sm"
          variant="outline"
          color="gray"
          icon="hero-document-duplicate"
          link_type="live_redirect"
          to={~p"/w/#{@current_scope.workspace.slug}/tasks?duplicate=#{@task.id}"}
          data-testid="task-duplicate"
        >
          Duplicar
        </.button>
        <.button
          :if={removable_worktree?(@task)}
          size="sm"
          variant="outline"
          color="gray"
          icon="hero-trash"
          phx-click="remove_worktree"
          data-confirm="Remover o worktree desta tarefa? O branch continua no repositório; o que não foi commitado se perde."
          data-testid="task-remove-worktree"
        >
          Remover worktree
        </.button>
        <.button
          :if={Task.active?(@task) and can?(@current_scope, :cancel_task, @task)}
          size="sm"
          variant="outline"
          color="danger"
          icon="hero-stop"
          phx-click="cancel"
          data-confirm="Cancelar esta tarefa?"
          data-testid="task-cancel"
        >
          Cancelar
        </.button>
      </:actions>

      <div class="space-y-6">
        <.card variant="outline">
          <.card_content>
            <div class="flex flex-wrap items-start justify-between gap-4">
              <div class="min-w-0 flex-1">
                <p class="text-sm text-gray-500 dark:text-gray-400" data-testid="task-pipeline-name">
                  {@task.pipeline_name} · v{@task.pipeline_version} · {stage_progress(@task)}
                </p>
                <pre
                  class="mt-2 whitespace-pre-wrap font-sans text-gray-900 dark:text-white"
                  data-testid="task-prompt-text"
                >{@task.prompt}</pre>
              </div>
              <.task_status task={@task} data-testid="task-status" />
            </div>
            <dl class="mt-4 grid gap-3 text-sm sm:grid-cols-4">
              <div>
                <dt class="text-gray-500 dark:text-gray-400">Custo</dt>
                <dd class="text-gray-900 dark:text-white" data-testid="task-cost">
                  {format_cost(@cost)}
                  <span
                    :if={@task.pipeline_context && @task.pipeline_context["max_cost_usd"]}
                    class="text-gray-500 dark:text-gray-400"
                  >
                    de US$ {@task.pipeline_context["max_cost_usd"]}
                  </span>
                </dd>
              </div>
              <div>
                <dt class="text-gray-500 dark:text-gray-400">Runner · diretório</dt>
                <dd class="font-mono text-xs text-gray-900 dark:text-white" data-testid="task-where">
                  {if @task.runner, do: @task.runner.name, else: "—"}:{@task.directory}
                </dd>
              </div>
              <div>
                <dt class="text-gray-500 dark:text-gray-400">Branch</dt>
                <dd class="font-mono text-xs text-gray-900 dark:text-white" data-testid="task-branch">
                  {@task.branch || "— (diretório sem git)"}
                </dd>
                <dd :if={@task.pr_url} class="mt-1 text-xs">
                  <a
                    href={@task.pr_url}
                    target="_blank"
                    rel="noopener"
                    class="text-primary-600 hover:underline dark:text-primary-400"
                    data-testid="task-pr"
                  >
                    Pull request <.icon name="hero-arrow-top-right-on-square" class="size-3" />
                  </a>
                </dd>
                <dd :if={@task.issue_url} class="mt-1 text-xs">
                  <a
                    href={@task.issue_url}
                    target="_blank"
                    rel="noopener"
                    class="text-primary-600 hover:underline dark:text-primary-400"
                    data-testid="task-issue"
                  >
                    {IntegrationComponents.issue_label(@task.issue_url)}
                    <.icon name="hero-arrow-top-right-on-square" class="size-3" />
                  </a>
                </dd>
                <dd
                  :if={@task.issue_feedback["error"]}
                  class="mt-1 text-xs text-warning-600 dark:text-warning-400"
                  data-testid="task-issue-sync-error"
                >
                  A issue ainda não mostra o andamento: {@task.issue_feedback["error"]}. A plataforma tenta de novo.
                </dd>
              </div>
              <div>
                <dt class="text-gray-500 dark:text-gray-400">Diretório de trabalho</dt>
                <dd
                  class="break-all font-mono text-xs text-gray-900 dark:text-white"
                  data-testid="task-worktree"
                >
                  {@task.worktree || "definido quando a primeira etapa termina"}
                </dd>
                <dd
                  :if={worktree_state(@task)}
                  class="mt-1 text-xs text-gray-500 dark:text-gray-400"
                  data-testid="task-worktree-state"
                >
                  {worktree_state(@task)}
                </dd>
              </div>
            </dl>
            <.alert
              :if={Tasks.runner_offline?(@task, @online)}
              color="danger"
              with_icon
              class="mt-4"
              data-testid="task-runner-offline"
            >
              <div class="flex flex-wrap items-center justify-between gap-2">
                <span>
                  A tarefa está parada: o runner {if @task.runner, do: @task.runner.name, else: "—"} está offline.
                  Interrompa a etapa para decidir: refazer em outro runner, seguir ou cancelar.
                </span>
                <.button
                  size="xs"
                  color="danger"
                  variant="outline"
                  icon="hero-hand-raised"
                  phx-click="interrupt"
                  data-testid="task-runner-offline-interrupt"
                >
                  Interromper a etapa
                </.button>
              </div>
            </.alert>
            <div :if={task_files(@task) != []} class="mt-4 text-sm">
              <p class="mb-1 text-gray-500 dark:text-gray-400">Arquivos alterados na tarefa</p>
              <.file_list files={task_files(@task)} data-testid="task-files" />
            </div>
          </.card_content>
        </.card>

        <ol class="relative space-y-0" data-testid="task-pipeline">
          <li
            :for={row <- stage_rows(@task)}
            class="relative flex gap-4 pb-8 last:pb-0"
            data-testid={"stage-#{row.stage.key}"}
          >
            <div
              :if={row.index < length(@task.stages) - 1}
              class="absolute left-4 top-9 -bottom-0 w-px bg-gray-200 dark:bg-gray-800"
              aria-hidden="true"
            />
            <.stage_marker state={row.state} number={row.index + 1} />

            <div class="min-w-0 flex-1">
              <div class="flex flex-wrap items-center gap-x-3 gap-y-1 pt-1">
                <h2 class={[
                  "text-base font-semibold",
                  row.state == :pending && "text-gray-400 dark:text-gray-500",
                  row.state != :pending && "text-gray-900 dark:text-white"
                ]}>
                  {row.stage.name}
                </h2>
                <.stage_state_badge state={row.state} data-testid={"stage-state-#{row.stage.key}"} />
                <.badge
                  :if={row.stage.group not in [nil, ""]}
                  size="xs"
                  variant="outline"
                  color="gray"
                  label={"em paralelo · #{row.stage.group}"}
                  data-testid={"stage-group-#{row.stage.key}"}
                />
                <span :if={length(row.runs) > 1} class="text-xs text-gray-500 dark:text-gray-400">
                  {length(row.runs)} tentativas
                </span>
                <.button
                  :if={redoable?(@task) and row.runs != []}
                  size="xs"
                  variant="ghost"
                  color="gray"
                  icon="hero-arrow-uturn-left"
                  phx-click="open_redo"
                  phx-value-index={row.index}
                  class="ml-auto"
                  data-testid={"stage-redo-#{row.stage.key}"}
                >
                  Refazer a partir daqui
                </.button>
              </div>

              <div :if={row.runs != []} class="mt-3 space-y-4">
                <.attempt
                  :for={run <- row.runs}
                  run={run}
                  many={length(row.runs) > 1}
                  live={run.job && run.job.id == @live_job_id}
                  spent={run.job && run.job.id == @live_job_id && @live_spent}
                  typing={@typing}
                  streams={@streams}
                  steps={run.job && Map.get(@timelines, run.job.id)}
                  steps_filter={(run.job && Map.get(@step_filters, run.job.id)) || "all"}
                  raw_artifact={MapSet.member?(@raw_artifacts, run.id)}
                  workspace_slug={@current_scope.workspace.slug}
                />
              </div>

              <.card
                :if={row.state == :awaiting}
                variant="outline"
                class="mt-4 border-warning-300 dark:border-warning-800"
                data-testid="decision-panel"
              >
                <.card_content>
                  <.alert color="warning" with_icon data-testid="decision-reason">
                    {@task.decision_reason}
                  </.alert>
                  <.analysis_state analysis={@questionnaire.analysis} />
                  <.live_component
                    :if={@questionnaire.questionnaire}
                    module={QuestionnaireLive}
                    id={"questionnaire-#{@task.id}"}
                    task_id={@task.id}
                    questionnaire={@questionnaire.questionnaire}
                    can_cancel={can?(@current_scope, :cancel_task, @task)}
                  />
                  <details
                    class="group mt-4 rounded-lg border border-gray-200 p-3 dark:border-gray-700"
                    open={
                      is_nil(@questionnaire.questionnaire) and @questionnaire.analysis != :running
                    }
                    id="decision-manual"
                    phx-mounted={JS.ignore_attributes(["open"])}
                    data-testid="decision-manual"
                  >
                    <summary
                      class="cursor-pointer text-sm font-medium text-gray-700 dark:text-gray-200"
                      data-testid="decision-manual-toggle"
                    >
                      Decidir sem responder
                    </summary>
                    <div class="mt-3 flex justify-end">
                      <.button
                        type="button"
                        size="sm"
                        variant="outline"
                        icon="hero-cpu-chip"
                        phx-click="suggest_decision"
                        data-testid="decision-suggest"
                      >
                        Sugerir com IA
                      </.button>
                    </div>
                    <.form for={@decision} id="decision-form" phx-submit="decide" class="mt-4">
                      <.markdown_editor
                        id="decision-instructions"
                        field={@decision[:instructions]}
                        label="Instruções para continuar (opcional)"
                        icon="hero-chat-bubble-left-right"
                        rows={3}
                        placeholder="Ex.: o problema acontece no Safari; ignore o módulo legado."
                        testid="decision-instructions"
                      />
                      <div :if={@options != []} class="mb-3">
                        <p class="mb-2 text-sm text-gray-600 dark:text-gray-300">
                          O agente propôs (refaz a etapa com a escolha e as instruções):
                        </p>
                        <div class="flex flex-wrap gap-2">
                          <.button
                            :for={{option, index} <- Enum.with_index(@options)}
                            type="submit"
                            name="choice"
                            value={option}
                            size="sm"
                            variant="outline"
                            color="primary"
                            data-testid={"decision-option-#{index}"}
                          >
                            {option}
                          </.button>
                        </div>
                      </div>
                      <div class="flex flex-wrap justify-end gap-2">
                        <.button
                          type="submit"
                          name="action"
                          value="retry"
                          variant="outline"
                          icon="hero-arrow-path"
                          data-testid="decision-retry"
                        >
                          Refazer etapa
                        </.button>
                        <.button
                          type="submit"
                          name="action"
                          value="advance"
                          icon="hero-forward"
                          data-testid="decision-advance"
                        >
                          Seguir para a próxima
                        </.button>
                      </div>
                    </.form>
                  </details>
                </.card_content>
              </.card>
            </div>
          </li>
        </ol>

        <.card :if={!Task.active?(@task)} variant="outline" data-testid="task-correct">
          <.card_content>
            <.section_heading
              icon="hero-wrench-screwdriver"
              title="Corrigir com um prompt"
              description="Roda no worktree e na branch desta tarefa como uma nova etapa, com as verificações, os gates e a entrega de sempre."
            />
            <.alert
              :if={no_pr?(@task)}
              color="warning"
              with_icon
              class="mb-3"
              data-testid="task-no-pr-warning"
            >
              A tarefa terminou sem PR: a entrega não chegou a abri-lo. Peça a correção abaixo.
            </.alert>
            <.form for={@correct_form} id="correct-form" phx-submit="correct">
              <.markdown_editor
                id="task-correct-text"
                field={@correct_form[:prompt]}
                label="O que fazer"
                icon="hero-chat-bubble-bottom-center-text"
                rows={3}
                placeholder="Ex.: resolva o conflito com a main; o PR acusou erro no CI; ajuste o que a revisão pediu."
                testid="task-correct-text"
              />
              <.rerun_runner
                form={@correct_form}
                runners={@runner_choices}
                online={@online}
                testid="task-correct-runner"
              />
              <div class="flex justify-end">
                <.button icon="hero-play" data-testid="task-correct-submit">Rodar a correção</.button>
              </div>
            </.form>
          </.card_content>
        </.card>

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
            <.rerun_runner
              form={@redo_form}
              runners={@runner_choices}
              online={@online}
              testid="stage-redo-runner"
            />
            <div class="flex justify-end gap-2">
              <.button type="button" variant="ghost" color="gray" phx-click="close_redo">
                Cancelar
              </.button>
              <.button type="submit" icon="hero-arrow-uturn-left" data-testid="stage-redo-submit">
                Refazer
              </.button>
            </div>
          </.form>
        </.modal>

        <.card :if={@decisions != []} variant="outline">
          <.card_header title="Decisões tomadas" />
          <.card_content>
            <ol class="space-y-3 text-sm" data-testid="task-decisions">
              <li :for={{decision, n} <- Enum.with_index(@decisions)} class="flex gap-3">
                <.icon name="hero-hand-raised" class="mt-0.5 size-4 shrink-0 text-warning-500" />
                <div class="min-w-0">
                  <p class="text-gray-900 dark:text-white">
                    <span class="font-medium">{decision_label(decision.action)}</span>
                    em "{stage_name(@task, decision.stage_index)}"
                    <span :if={decision.choice}>· escolha: {decision.choice}</span>
                  </p>
                  <.answer_list
                    :if={decision.answers}
                    answers={Map.merge(decision.questions || %{}, decision.answers)}
                    class="my-1 space-y-1 text-sm"
                    data-testid={"task-decision-answers-#{n}"}
                  />
                  <p :if={decision.instructions} class="text-gray-600 dark:text-gray-300">
                    {decision.instructions}
                  </p>
                  <p class="text-xs text-gray-500 dark:text-gray-400">
                    {if decision.decided_by_user, do: decision.decided_by_user.name, else: "—"}
                    <span :if={decision.decided_via} data-testid={"task-decision-via-#{n}"}>
                      (via {decision.decided_via})
                    </span>
                    · {Calendar.strftime(
                      decision.inserted_at,
                      "%d/%m %H:%M"
                    )}
                  </p>
                </div>
              </li>
            </ol>
          </.card_content>
        </.card>

        <.card
          :if={@task.status == :running or (Task.active?(@task) and @task.pending_instructions)}
          variant="outline"
        >
          <.card_content>
            <div
              :if={@task.pending_instructions}
              class="mb-3 rounded-lg bg-info-50 px-3 py-2 text-sm text-info-900 dark:bg-info-950/40 dark:text-info-100"
              data-testid="task-pending-instructions"
            >
              <p class="font-medium">Vai na próxima tentativa ou etapa:</p>
              <p class="whitespace-pre-wrap">{@task.pending_instructions}</p>
            </div>
            <.form
              :if={@task.status == :running}
              for={to_form(%{"text" => ""}, as: "instruct")}
              id="instruct-form"
              phx-submit="instruct"
            >
              <.markdown_editor
                id="task-instruct-text"
                field={to_form(%{"text" => ""}, as: "instruct")[:text]}
                label="Mensagem para a tarefa"
                icon="hero-chat-bubble-bottom-center-text"
                rows={2}
                placeholder="Ex.: não mexa no módulo de pagamentos."
                help_text="Não interrompe a etapa em execução: entra no prompt da próxima tentativa ou etapa."
                testid="task-instruct-text"
              />
              <div class="flex flex-wrap items-center justify-end gap-2">
                <span
                  :if={@task.pause_requested}
                  class="text-sm text-warning-700 dark:text-warning-400"
                  data-testid="task-pause-requested"
                >
                  Pausa pedida: a tarefa para quando esta etapa terminar.
                </span>
                <.button
                  :if={@task.status == :running and not @task.pause_requested}
                  type="button"
                  variant="outline"
                  color="gray"
                  icon="hero-pause"
                  phx-click="request_pause"
                  data-testid="task-request-pause"
                >
                  Pausar depois desta etapa
                </.button>
                <.button
                  :if={@task.status == :running}
                  type="button"
                  variant="outline"
                  color="warning"
                  icon="hero-hand-raised"
                  phx-click="interrupt"
                  data-confirm="Interromper a etapa em execução? A tarefa vai aguardar uma decisão: refazer com instruções, seguir ou cancelar."
                  data-testid="task-interrupt"
                >
                  Interromper agora
                </.button>
                <.button icon="hero-paper-airplane" data-testid="task-instruct">Enviar</.button>
              </div>
            </.form>
          </.card_content>
        </.card>
      </div>
    </Layouts.app>
    """
  end

  attr :form, Phoenix.HTML.Form, required: true
  attr :runners, :list, required: true
  attr :online, :any, required: true
  attr :testid, :string, required: true

  # Which runner runs it: offered only when there is more than one choice.
  defp rerun_runner(assigns) do
    ~H"""
    <.icon_field
      :if={length(@runners) > 1}
      field={@form[:runner_id]}
      icon="hero-server-stack"
      type="select"
      label="Runner"
      options={runner_options(@runners, @online)}
      help_text="Outro runner monta o worktree a partir da branch da tarefa no origin."
      data-testid={@testid}
    />
    """
  end

  attr :state, :atom, required: true
  attr :number, :integer, required: true

  defp stage_marker(assigns) do
    ~H"""
    <div class={[
      "relative z-10 flex size-8 shrink-0 items-center justify-center rounded-full text-sm font-semibold ring-4 ring-gray-50 dark:ring-gray-950",
      marker_class(@state)
    ]}>
      <.icon :if={@state == :passed} name="hero-check" class="size-4" />
      <.icon :if={@state in [:failed, :canceled]} name="hero-x-mark" class="size-4" />
      <.icon :if={@state in [:awaiting, :blocked]} name="hero-hand-raised" class="size-4" />
      <.icon :if={@state == :running} name="hero-arrow-path" class="size-4 animate-spin" />
      <span :if={@state == :pending}>{@number}</span>
    </div>
    """
  end

  defp marker_class(:passed), do: "bg-success-500 text-white"
  defp marker_class(:running), do: "bg-info-500 text-white"
  defp marker_class(state) when state in [:awaiting, :blocked], do: "bg-warning-400 text-gray-900"
  defp marker_class(state) when state in [:failed, :canceled], do: "bg-danger-500 text-white"

  defp marker_class(:pending),
    do: "bg-gray-100 text-gray-500 dark:bg-gray-800 dark:text-gray-400"

  attr :state, :atom, required: true
  attr :rest, :global

  defp stage_state_badge(assigns) do
    {label, color} =
      case assigns.state do
        :pending -> {"Aguardando", "gray"}
        :running -> {"Executando", "info"}
        :awaiting -> {"Aguardando decisão", "warning"}
        :passed -> {"Concluída", "success"}
        :blocked -> {"Bloqueada", "warning"}
        :failed -> {"Falhou", "danger"}
        :canceled -> {"Cancelada", "gray"}
      end

    assigns = assign(assigns, label: label, color: color)

    ~H"""
    <.badge size="xs" variant="soft" color={@color} label={@label} {@rest} />
    """
  end

  attr :run, StageRun, required: true
  attr :many, :boolean, required: true
  attr :live, :boolean, required: true
  attr :spent, :any, default: nil, doc: "what the running attempt spent so far"
  attr :streams, :any, required: true
  attr :steps, :list, default: nil
  attr :steps_filter, :string, default: "all"
  attr :raw_artifact, :boolean, default: false
  attr :typing, :string, default: nil
  attr :workspace_slug, :string, required: true

  defp attempt(assigns) do
    ~H"""
    <div
      class="rounded-xl border border-gray-200 bg-white dark:border-gray-800 dark:bg-gray-900"
      data-testid={"stage-run-#{@run.key}-#{@run.attempt}"}
    >
      <div class="flex flex-wrap items-center justify-between gap-2 border-b border-gray-100 px-4 py-2 text-xs text-gray-500 dark:border-gray-800 dark:text-gray-400">
        <span>
          <span :if={@many}>Tentativa {@run.attempt} · </span>
          <.stage_run_status run={@run} data-testid={"stage-run-status-#{@run.key}-#{@run.attempt}"} />
        </span>
        <span :if={@run.job} class="flex items-center gap-3">
          <span
            :if={@spent}
            class="text-primary-700 dark:text-primary-300"
            data-testid={"stage-run-spent-#{@run.key}-#{@run.attempt}"}
          >
            até agora {format_cost(@spent.cost_usd)} · {short_number(@spent.tokens)} tokens
          </span>
          <span>{format_duration(@run.job.duration_ms)}</span>
          <span>{format_cost(@run.job.cost_usd)}</span>
          <span
            :if={Job.tokens(@run.job) > 0}
            data-testid={"stage-run-tokens-#{@run.key}-#{@run.attempt}"}
          >
            {short_number(Job.tokens(@run.job))} tokens · {format_percent(Job.cache_hit(@run.job))} do cache
          </span>
          <.link
            navigate={~p"/w/#{@workspace_slug}/jobs/#{@run.job.id}"}
            class="text-primary-600 hover:underline dark:text-primary-400"
            data-testid={"stage-run-audit-#{@run.key}-#{@run.attempt}"}
          >
            Execução e auditoria
          </.link>
        </span>
      </div>

      <div class="space-y-3 px-4 py-3">
        <.setup_report
          :if={@run.job && @run.job.setup}
          setup={@run.job.setup}
          data-testid={"stage-run-setup-#{@run.key}-#{@run.attempt}"}
        />

        <.changes_report
          :if={@run.job && @run.job.changes}
          changes={@run.job.changes}
          id={"#{@run.key}-#{@run.attempt}"}
        />

        <details
          :if={@run.feedback}
          class="rounded-lg bg-warning-50 px-3 py-2 text-sm dark:bg-warning-950/30"
          data-testid={"stage-run-feedback-#{@run.key}-#{@run.attempt}"}
        >
          <summary class="cursor-pointer text-warning-800 dark:text-warning-300">
            Feedback da tentativa anterior
          </summary>
          <pre class="mt-2 max-h-64 overflow-auto whitespace-pre-wrap break-words font-mono text-xs text-gray-800 dark:text-gray-200">{@run.feedback}</pre>
        </details>

        <div
          :if={@run.answers}
          class="text-sm"
          data-testid={"stage-run-answers-#{@run.key}-#{@run.attempt}"}
        >
          <span class="font-medium text-gray-900 dark:text-white">Respostas da pessoa:</span>
          <.answer_list answers={@run.answers} class="mt-1 space-y-1 text-sm" />
        </div>

        <p :if={@run.instructions} class="text-sm text-gray-600 dark:text-gray-300">
          <span class="font-medium">Instruções:</span> {@run.instructions}
        </p>

        <p
          :if={@run.summary}
          class="text-sm font-medium text-gray-900 dark:text-white"
          data-testid={"stage-run-summary-#{@run.key}-#{@run.attempt}"}
        >
          {@run.summary}
        </p>

        <p :if={@run.error} class="text-sm text-danger-700 dark:text-danger-400">{@run.error}</p>

        <div
          :if={plain_result?(@run)}
          id={"result-#{@run.id}"}
          phx-hook="Highlight"
          class="prose prose-sm max-h-[32rem] max-w-none overflow-auto prose-h1:text-xl prose-h2:text-lg prose-h3:text-base rounded-lg bg-gray-50 px-4 py-3 dark:prose-invert dark:bg-gray-950"
          data-testid={"stage-run-result-#{@run.key}-#{@run.attempt}"}
        >
          {Markdown.to_html(@run.job.result)}
        </div>

        <p
          :if={@run.job && @run.job.delivery && @run.job.delivery["commit"]}
          class="text-xs text-gray-500 dark:text-gray-400"
          data-testid={"stage-run-commit-#{@run.key}-#{@run.attempt}"}
        >
          <.icon name="hero-check-badge" class="size-4 text-success-600" /> Commit
          <span class="font-mono">{String.slice(@run.job.delivery["commit"], 0, 7)}</span>
          <span :if={@run.job.delivery["pushed"]}>· enviado</span>
        </p>
        <p
          :if={@run.job && @run.job.delivery && @run.job.delivery["error"]}
          class="text-xs text-danger-700 dark:text-danger-400"
        >
          A entrega falhou: {@run.job.delivery["error"]}
        </p>

        <.gate_results
          :if={@run.job && @run.job.gates not in [nil, []]}
          gates={@run.job.gates}
          id={"#{@run.key}-#{@run.attempt}"}
        />

        <div :if={@run.artifact}>
          <div class="mb-1 flex items-center justify-between">
            <p class="text-xs font-medium uppercase tracking-wide text-gray-500 dark:text-gray-400">
              Artefato
            </p>
            <button
              type="button"
              phx-click="toggle_artifact"
              phx-value-run={@run.id}
              class="text-xs font-medium text-gray-500 hover:text-gray-900 dark:text-gray-400 dark:hover:text-white"
              data-testid={"stage-run-artifact-toggle-#{@run.key}-#{@run.attempt}"}
            >
              {if @raw_artifact, do: "Ver renderizado", else: "Ver texto"}
            </button>
          </div>
          <div
            :if={!@raw_artifact}
            id={"artifact-#{@run.id}"}
            phx-hook="Highlight"
            class="prose prose-sm max-h-[40rem] max-w-none overflow-auto prose-h1:text-xl prose-h2:text-lg prose-h3:text-base rounded-lg bg-gray-50 px-4 py-3 dark:prose-invert dark:bg-gray-950"
            data-testid={"stage-run-artifact-#{@run.key}-#{@run.attempt}"}
          >
            {Markdown.to_html(@run.artifact)}
          </div>
          <pre
            :if={@raw_artifact}
            class="max-h-[40rem] overflow-auto whitespace-pre-wrap break-words rounded-lg bg-gray-50 px-4 py-3 font-mono text-sm text-gray-800 dark:bg-gray-950 dark:text-gray-100"
            data-testid={"stage-run-artifact-raw-#{@run.key}-#{@run.attempt}"}
          >{@run.artifact}</pre>
        </div>

        <div :if={@live}>
          <p class="mb-3 text-xs font-medium uppercase tracking-wide text-info-600 dark:text-info-400">
            Ao vivo
          </p>
          <ol id="task-events" phx-update="stream" class="space-y-3" data-testid="task-events">
            <.timeline_segment
              :for={{id, segment} <- @streams.timeline}
              id={id}
              timeline="task-events"
              segment={segment}
            />
          </ol>
          <.typing :if={@typing} text={@typing} />
        </div>

        <div :if={@run.job && !@live}>
          <button
            type="button"
            phx-click="toggle_steps"
            phx-value-job={@run.job.id}
            class="text-sm font-medium text-gray-600 hover:text-gray-900 dark:text-gray-300 dark:hover:text-white"
            data-testid={"stage-run-steps-toggle-#{@run.key}-#{@run.attempt}"}
          >
            <.icon
              name={if @steps, do: "hero-chevron-down", else: "hero-chevron-right"}
              class="size-4"
            /> Passo a passo do agente
          </button>
          <div :if={@steps} class="mt-2 flex flex-wrap gap-1">
            <.button
              :for={
                {filter, label} <- [
                  {"all", "Tudo"},
                  {"agent", "Agente"},
                  {"tools", "Ferramentas"},
                  {"thinking", "Raciocínio"},
                  {"errors", "Erros"}
                ]
              }
              size="xs"
              variant={if @steps_filter == filter, do: "solid", else: "ghost"}
              color="gray"
              phx-click="filter_steps"
              phx-value-job={@run.job.id}
              phx-value-filter={filter}
              data-testid={"stage-run-steps-filter-#{@run.key}-#{@run.attempt}-#{filter}"}
            >
              {label}
            </.button>
          </div>
          <.steps
            :if={@steps}
            items={timeline_items(@steps, @steps_filter)}
            id={"#{@run.key}-#{@run.attempt}"}
          />
        </div>
      </div>
    </div>
    """
  end

  attr :gates, :list, required: true
  attr :id, :string, required: true

  # The stage's gate commands, each met or not, its output folded.
  defp gate_results(assigns) do
    ~H"""
    <div data-testid={"stage-run-gates-#{@id}"}>
      <p class="mb-1 text-xs font-medium uppercase tracking-wide text-gray-500 dark:text-gray-400">
        Gates
      </p>
      <ul class="space-y-1">
        <li
          :for={{gate, index} <- Enum.with_index(@gates)}
          data-testid={"stage-run-gate-#{@id}-#{index}"}
          data-passed={to_string(gate["passed"])}
        >
          <details class="text-sm">
            <summary class="flex cursor-pointer items-center gap-2">
              <.icon
                name={if gate["passed"], do: "hero-check-circle", else: "hero-x-circle"}
                class={[
                  "size-4 shrink-0",
                  if(gate["passed"],
                    do: "text-success-600 dark:text-success-400",
                    else: "text-danger-600 dark:text-danger-400"
                  )
                ]}
              />
              <code
                :if={!gate["platform"]}
                class="break-all text-xs text-gray-800 dark:text-gray-200"
              >
                {gate["command"]}
              </code>
              <span :if={gate["platform"]} class="text-xs text-gray-800 dark:text-gray-200">
                <.badge color="info" size="sm" data-testid={"stage-run-gate-platform-#{@id}-#{index}"}>
                  plataforma
                </.badge>
                {String.replace_prefix(gate["command"] || "", "plataforma: ", "")}
              </span>
              <span :if={!gate["platform"]} class="shrink-0 text-xs text-gray-500 dark:text-gray-400">
                {if gate["expect"] == "fail", do: "deve falhar", else: "deve passar"} · código {gate[
                  "exit_code"
                ]}
              </span>
            </summary>
            <pre
              :if={gate["output"] not in [nil, ""]}
              class="mt-1 max-h-64 overflow-auto whitespace-pre-wrap break-words rounded-lg bg-gray-50 px-3 py-2 font-mono text-xs text-gray-800 dark:bg-gray-950 dark:text-gray-100"
            >{gate["output"]}</pre>
          </details>
        </li>
      </ul>
    </div>
    """
  end

  attr :setup, :map, required: true
  attr :rest, :global

  # How the runner prepared the task's worktree, on the attempt that created it.
  defp setup_report(assigns) do
    ~H"""
    <details class="rounded-lg bg-gray-50 px-3 py-2 text-sm dark:bg-gray-950" {@rest}>
      <summary class="cursor-pointer text-gray-700 dark:text-gray-300">
        <.icon name="hero-wrench-screwdriver" class="size-4" />
        Ambiente preparado em {format_duration(@setup["duration_ms"])}
        <span :if={@setup["copied"] != []} class="text-gray-500 dark:text-gray-400">
          · copiado: {Enum.join(@setup["copied"] || [], ", ")}
        </span>
        <span :if={@setup["command"]} class="text-gray-500 dark:text-gray-400">
          · <code>{@setup["command"]}</code> (código {@setup["exit_code"]})
        </span>
      </summary>
      <pre
        :if={@setup["output"] not in [nil, ""]}
        class="mt-2 max-h-80 overflow-auto whitespace-pre-wrap break-words font-mono text-xs text-gray-700 dark:text-gray-300"
      >{@setup["output"]}</pre>
    </details>
    """
  end

  # The agent's final answer, for a stage without structured output; with
  # one, the summary above already says it and the raw JSON would repeat it.
  defp plain_result?(%StageRun{status: status, structured_output: nil, job: %{result: result}})
       when status != :running and is_binary(result),
       do: true

  defp plain_result?(_run), do: false
end
