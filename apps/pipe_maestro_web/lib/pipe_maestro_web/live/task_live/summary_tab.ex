defmodule PipeMaestroWeb.TaskLive.SummaryTab do
  @moduledoc """
  The task's "Resumo" tab: its pipeline and progress, what it cost against
  its cap, the project and where it runs, the branch, pull request, merge and
  issue, and the worktree with its state.
  """
  use PipeMaestroWeb, :html

  import PipeMaestroWeb.JobComponents, only: [format_cost: 1]
  import PipeMaestroWeb.TaskComponents, only: [stage_progress: 1]

  alias PipeMaestro.Tasks.Task
  alias PipeMaestroWeb.IntegrationComponents

  attr :task, Task, required: true
  attr :cost, :any, required: true
  attr :slug, :string, required: true

  @doc "The tab."
  @spec summary(map()) :: Phoenix.LiveView.Rendered.t()
  def summary(assigns) do
    ~H"""
    <.card variant="outline">
      <.card_content>
        <p class="text-sm text-gray-500 dark:text-gray-400" data-testid="task-pipeline-name">
          {@task.pipeline_name} · v{@task.pipeline_version} · {stage_progress(@task)}
        </p>
        <dl class="mt-4 grid gap-4 text-sm sm:grid-cols-2 lg:grid-cols-4">
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
            <dt class="text-gray-500 dark:text-gray-400">Projeto</dt>
            <dd class="text-gray-900 dark:text-white" data-testid="task-project">
              <.link
                :if={@task.project_id}
                navigate={~p"/w/#{@slug}/projects/#{@task.project_id}/edit"}
                class="text-primary-600 hover:underline dark:text-primary-400"
              >
                {(@task.project || %{})["name"] || @task.directory}
              </.link>
              <span :if={!@task.project_id}>
                {(@task.project || %{})["name"] || "sem projeto"}
              </span>
            </dd>
            <dd
              class="font-mono text-xs text-gray-500 dark:text-gray-400"
              data-testid="task-where"
            >
              {if @task.runner, do: @task.runner.name, else: "—"}:{@task.directory}
            </dd>
          </div>
          <div>
            <dt class="text-gray-500 dark:text-gray-400">Branch</dt>
            <dd
              class="font-mono text-xs text-gray-900 dark:text-white"
              data-testid="task-branch"
            >
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
            <dd
              :if={@task.merge_state == "blocked" and @task.merge_reason}
              class="mt-1 text-xs text-gray-600 dark:text-gray-300"
              data-testid="task-merge-reason"
            >
              O merge parou: {@task.merge_reason}
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
      </.card_content>
    </.card>
    """
  end

  defp worktree_state(%Task{worktree_removed_at: %DateTime{}}), do: "Removido do runner."

  defp worktree_state(%Task{worktree_removal_requested_at: %DateTime{}}),
    do: "Removendo: aguardando o runner."

  defp worktree_state(%Task{worktree_error: error}) when is_binary(error),
    do: "Não foi possível remover: #{error}"

  defp worktree_state(_task), do: nil
end
