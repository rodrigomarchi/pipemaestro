defmodule PipeMaestroWeb.TaskLive.StagePanel do
  @moduledoc """
  One stage of a task, in a panel 90% of the screen wide, opened on demand
  from the task's pipeline (`?etapa=<key>`). The stage's attempts are read
  only here, in full (`PipeMaestro.Tasks.stage_attempts/2`), and read again
  only when the page says they changed (`fingerprint`).

  It shows one attempt at a time, the latest unless another is picked; a
  stage that never ran says what it will do; a stage the task waits on leads
  with the decision (`PipeMaestroWeb.TaskLive.DecisionPanel`).

  The attempt running now (`live_job_id`, the job the page follows) shows
  its steps live: its timeline is read once when it opens and grows from the
  events the page hands over (`send_update/3` with `job_event`, `job_delta`
  and `spent`). When it ends, the page's fingerprint changes and the panel
  turns to what the attempt produced.

  An attempt opens in tabs (`PipeMaestroWeb.TaskLive.AttemptComponents`),
  what it produced first; a stage that never ran, its details in tabs too.

  The component keeps the panel's state: the attempt picked and the tab
  open, the artifacts shown as text, the finished steps read (when the
  "Passos" tab opens) and their filters, the live timeline, what is being
  typed and what was spent so far.
  """
  use PipeMaestroWeb, :live_component

  import PipeMaestroWeb.JobComponents,
    only: [timeline_items: 2, timeline_push: 2, timeline_tail: 1]

  import PipeMaestroWeb.PipelineComponents,
    only: [side_panel: 1, stage_details: 1, stage_state_badge: 1]

  alias PipeMaestro.{Insights, Jobs, Tasks}
  alias PipeMaestro.Jobs.Job
  alias PipeMaestro.Tasks.StageRun
  alias PipeMaestroWeb.PipelineDiagram
  alias PipeMaestroWeb.TaskLive.{AttemptComponents, DecisionPanel}

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(index: nil, fingerprint: nil, live_job_id: nil, runs: [], attempt: nil)
     |> assign(tab: nil)
     |> assign(raw_artifacts: MapSet.new(), timelines: %{}, step_filters: %{})
     |> assign(typing: nil, spent: nil, timeline_tail: nil)
     |> stream(:timeline, [])}
  end

  @impl true
  def update(%{job_event: event}, socket) do
    with true <- event.job_id == socket.assigns.live_job_id,
         {segment, tail} when segment != :seen <-
           timeline_push(socket.assigns.timeline_tail, event) do
      {:ok,
       socket
       |> stream_insert(:timeline, segment)
       |> assign(timeline_tail: tail, typing: nil)}
    else
      _other_job_or_seen -> {:ok, socket}
    end
  end

  def update(%{job_delta: {job_id, text}}, socket) do
    if job_id == socket.assigns.live_job_id,
      do: {:ok, assign(socket, typing: text)},
      else: {:ok, socket}
  end

  def update(%{spent: {job_id, spent}}, socket) do
    if job_id == socket.assigns.live_job_id,
      do: {:ok, assign(socket, spent: spent)},
      else: {:ok, socket}
  end

  def update(assigns, socket) do
    before = socket.assigns
    socket = assign(socket, assigns)
    moved? = before.index != assigns.index
    live_changed? = before.live_job_id != assigns.live_job_id

    socket =
      if moved? or live_changed? or before.fingerprint != assigns.fingerprint,
        do: reload(socket, moved?),
        else: socket

    socket = if moved? or live_changed?, do: follow(socket), else: socket

    {:ok, socket}
  end

  # The stage's attempts, read again; the latest is picked when the stage
  # changes or a new attempt appears.
  defp reload(socket, moved?) do
    runs = Tasks.stage_attempts(socket.assigns.task, socket.assigns.index)
    latest = runs |> List.last() |> then(&(&1 && &1.attempt))

    attempt =
      if moved? or is_nil(socket.assigns.attempt) or
           AttemptComponents.attempts(runs) > AttemptComponents.attempts(socket.assigns.runs),
         do: latest,
         else: socket.assigns.attempt

    socket = assign(socket, runs: runs, attempt: attempt)

    if moved?,
      do:
        assign(socket,
          raw_artifacts: MapSet.new(),
          timelines: %{},
          step_filters: %{},
          tab: nil
        ),
      else: socket
  end

  # The live timeline starts from what the followed job already said.
  defp follow(socket) do
    case live_job(socket.assigns) do
      nil ->
        socket |> assign(typing: nil, spent: nil) |> live_timeline([])

      job ->
        socket
        |> assign(typing: nil, spent: Insights.live(job))
        |> live_timeline(Jobs.list_events(job))
    end
  end

  defp live_job(%{live_job_id: nil}), do: nil

  defp live_job(%{live_job_id: id, runs: runs}),
    do: Enum.find_value(runs, fn run -> run.job && run.job.id == id && run.job end)

  defp live_timeline(socket, events) do
    segments = timeline_items(events, "all")

    socket
    |> assign(timeline_tail: timeline_tail(segments))
    |> stream(:timeline, segments, reset: true)
  end

  @impl true
  def handle_event("select_tab", %{"tab" => tab}, socket),
    do: {:noreply, socket |> assign(tab: tab) |> load_shown_steps()}

  def handle_event("select_attempt", %{"attempt" => attempt}, socket),
    do: {:noreply, socket |> assign(attempt: String.to_integer(attempt)) |> load_shown_steps()}

  # An artifact shows rendered; this flips one between that and its text.
  def handle_event("toggle_artifact", %{"run" => run_id}, socket) do
    raw = socket.assigns.raw_artifacts

    raw =
      if MapSet.member?(raw, run_id),
        do: MapSet.delete(raw, run_id),
        else: MapSet.put(raw, run_id)

    {:noreply, assign(socket, raw_artifacts: raw)}
  end

  # A finished attempt's steps are read only when someone asks for them.
  def handle_event("load_steps", %{"job" => job_id}, socket) do
    jobs = for %{job: %{id: ^job_id} = job} <- socket.assigns.runs, do: job
    {:noreply, load_steps(socket, jobs)}
  end

  def handle_event("filter_steps", %{"job" => job_id, "filter" => filter}, socket)
      when filter in ~w(all agent tools thinking errors),
      do: {:noreply, update(socket, :step_filters, &Map.put(&1, job_id, filter))}

  # The steps of the attempt shown, read when its "Passos" tab opens.
  defp load_shown_steps(%{assigns: %{tab: "passos"}} = socket) do
    jobs =
      for %{attempt: attempt, job: %Job{} = job} <- socket.assigns.runs,
          attempt == socket.assigns.attempt,
          do: job

    load_steps(socket, jobs)
  end

  defp load_shown_steps(socket), do: socket

  defp load_steps(socket, jobs) do
    timelines =
      Enum.reduce(jobs, socket.assigns.timelines, fn job, timelines ->
        Map.put_new_lazy(timelines, job.id, fn -> Jobs.list_events(job) end)
      end)

    assign(socket, timelines: timelines)
  end

  @impl true
  def render(assigns) do
    task = assigns.task
    stage = Enum.at(task.stages, assigns.index)

    assigns =
      assign(assigns,
        stage: stage,
        state: Map.fetch!(PipelineDiagram.task_states(task), assigns.index),
        attempt_numbers: assigns.runs |> Enum.map(& &1.attempt) |> Enum.uniq(),
        shown: Enum.filter(assigns.runs, &(&1.attempt == assigns.attempt))
      )

    ~H"""
    <div id={@id}>
      <.side_panel
        id={"#{@id}-aside"}
        title={@stage.name}
        open
        testid="task-stage-panel"
      >
        <div class="space-y-4">
          <div class="flex flex-wrap items-center gap-2">
            <.stage_state_badge state={@state} data-testid="task-stage-panel-state" />
            <.badge
              :if={@stage.group not in [nil, ""]}
              size="xs"
              variant="outline"
              color="gray"
              label={"em paralelo · #{@stage.group}"}
            />
            <.button
              :if={@redoable and @runs != []}
              size="xs"
              variant="outline"
              color="gray"
              icon="hero-arrow-uturn-left"
              phx-click="open_redo"
              phx-value-index={@index}
              class="ml-auto"
              data-testid={"stage-redo-#{@stage.key}"}
            >
              Refazer a partir daqui
            </.button>
          </div>

          <DecisionPanel.decision_panel
            :if={@state == :awaiting}
            task={@task}
            questionnaire={@questionnaire}
            options={@options}
            form={@decision}
            can_cancel={@can_cancel}
          />

          <div :if={@runs == []} class="space-y-4" data-testid="task-stage-panel-pending">
            <p class="text-sm text-gray-500 dark:text-gray-400">
              Esta etapa ainda não rodou. Quando chegar a vez dela, o agente recebe:
            </p>
            <.stage_details stage={@stage} tab={@tab} target={@myself} />
          </div>

          <div
            :if={length(@attempt_numbers) > 1}
            class="flex flex-wrap gap-1"
            role="tablist"
            data-testid="task-stage-attempts"
          >
            <.button
              :for={n <- @attempt_numbers}
              size="xs"
              variant={if n == @attempt, do: "solid", else: "outline"}
              color={if n == @attempt, do: "primary", else: "gray"}
              phx-click="select_attempt"
              phx-value-attempt={n}
              phx-target={@myself}
              role="tab"
              aria-selected={to_string(n == @attempt)}
              data-testid={"task-stage-attempt-#{@stage.key}-#{n}"}
            >
              Tentativa {n}
            </.button>
          </div>

          <AttemptComponents.attempt
            :for={run <- @shown}
            run={run}
            many={length(@attempt_numbers) > 1 or length(@shown) > 1}
            live={live?(run, @live_job_id)}
            spent={live?(run, @live_job_id) && @spent}
            typing={@typing}
            streams={@streams}
            steps={run.job && Map.get(@timelines, run.job.id)}
            steps_filter={(run.job && Map.get(@step_filters, run.job.id)) || "all"}
            raw_artifact={MapSet.member?(@raw_artifacts, run.id)}
            files={Map.get(@files, run.id, [])}
            prompt={@stage.prompt}
            tab={@tab}
            workspace_slug={@slug}
            target={@myself}
          />
        </div>
      </.side_panel>
    </div>
    """
  end

  defp live?(%StageRun{job: %{id: id}}, id) when not is_nil(id), do: true
  defp live?(_run, _live_job_id), do: false
end
