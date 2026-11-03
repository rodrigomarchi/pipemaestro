defmodule ClaudeControlPlaneWeb.DecisionsLive do
  @moduledoc """
  Everything in the workspace that waits for a person: each task paused for a
  decision, with the stage, the reason, and the decision itself (retry the
  stage or move on, optionally with instructions, or cancel the task).
  Updated live.
  """
  use ClaudeControlPlaneWeb, :live_view

  import ClaudeControlPlaneWeb.RunnerComponents, only: [time_ago: 2]

  alias ClaudeControlPlane.Tasks
  alias ClaudeControlPlane.Tasks.Task

  @impl true
  def mount(_params, _session, socket) do
    workspace = socket.assigns.current_scope.workspace
    if connected?(socket), do: Tasks.subscribe({:workspace, workspace.id})
    {:ok, socket |> assign(page_title: "Decisões") |> load()}
  end

  @impl true
  def handle_info({:task_updated, _task}, socket), do: {:noreply, load(socket)}

  @impl true
  # An option button sends the choice without an action: it retries the stage.
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

    socket =
      case result do
        {:ok, _task} -> put_flash(socket, :info, "Decisão registrada: #{task.title}.")
        {:error, _reason} -> put_flash(socket, :error, "Essa tarefa não espera mais decisão.")
      end

    {:noreply, load(socket)}
  end

  defp load(socket) do
    tasks = Tasks.list_awaiting(socket.assigns.current_scope.workspace)

    assign(socket,
      tasks: tasks,
      options: Map.new(tasks, &{&1.id, Tasks.options(&1)}),
      now: DateTime.utc_now()
    )
  end

  defp stage_name(%Task{stages: stages, current_stage: index}) do
    case Enum.at(stages, index) do
      nil -> "—"
      stage -> "#{index + 1}/#{length(stages)} · #{stage.name}"
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      pending_decisions={@pending_decisions}
      current_scope={@current_scope}
      workspaces={@workspaces}
      active={:decisions}
      title="Decisões"
    >
      <div class="space-y-4">
        <.empty
          :if={@tasks == []}
          title="Nenhuma decisão pendente"
          description="Quando uma etapa pedir ajuda, esgotar as tentativas ou pedir aprovação, a tarefa aparece aqui."
          data-testid="no-decisions"
        >
          <:icon><.icon name="hero-check-circle" /></:icon>
        </.empty>

        <.card
          :for={task <- @tasks}
          variant="outline"
          class="border-warning-300 dark:border-warning-800"
          data-testid={"decision-#{task.id}"}
        >
          <.card_content>
            <div class="flex flex-wrap items-start justify-between gap-2">
              <div class="min-w-0">
                <.link
                  navigate={~p"/w/#{@current_scope.workspace.slug}/tasks/#{task.id}"}
                  class="font-semibold text-gray-900 hover:underline dark:text-white"
                  data-testid={"decision-link-#{task.id}"}
                >
                  {task.title}
                </.link>
                <p class="text-sm text-gray-500 dark:text-gray-400">
                  {task.pipeline_name} · {stage_name(task)} ·
                  <span class="font-mono text-xs">
                    {if task.runner, do: task.runner.name, else: "—"}:{task.directory}
                  </span>
                </p>
              </div>
              <span class="text-xs text-gray-500 dark:text-gray-400">
                esperando {time_ago(task.updated_at, @now)}
              </span>
            </div>

            <.alert color="warning" with_icon class="mt-3">{task.decision_reason}</.alert>

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
              <.field
                field={to_form(%{}, as: "decision")[:instructions]}
                id={"decision-instructions-#{task.id}"}
                type="textarea"
                rows="2"
                label="Instruções para continuar (opcional)"
                data-testid={"decision-instructions-#{task.id}"}
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
          </.card_content>
        </.card>
      </div>
    </Layouts.app>
    """
  end
end
