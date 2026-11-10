defmodule PipeMaestroWeb.TaskLive.NodePanel do
  @moduledoc """
  The drawer of a place on the task's pipeline that is not a stage
  (`PipeMaestroWeb.TaskLive.PipelineView`), in tabs, what matters first:

    * `"entrada"`: the request, rendered; then the project, where it runs,
      the branch, the worktree and the issue.
    * `"entrega"`: the files the task changed; then the pull request and its
      merge.
    * `"fim"`: what the task cost against its cap and how far it went; then
      the files the stages sent (and the files changed, when no pull request
      is delivered).
    * `"corrigir"`: the correction of a task that ended.

  The tab open is the page's (`select_tab`).
  """
  use PipeMaestroWeb, :html

  import PipeMaestroWeb.JobComponents, only: [format_cost: 1]
  import PipeMaestroWeb.JobFileComponents, only: [files: 1]

  import PipeMaestroWeb.PipelineComponents,
    only: [chosen_tab: 2, drawer_tabs: 1, side_panel: 1]

  import PipeMaestroWeb.TabComponents, only: [tab_panel: 1]
  import PipeMaestroWeb.TaskComponents, only: [file_list: 1, stage_progress: 1]

  alias PipeMaestro.Tasks.Task
  alias PipeMaestroWeb.{IntegrationComponents, Markdown}
  alias PipeMaestroWeb.TaskLive.PipelineView

  @nodes ~w(entrada entrega fim corrigir)

  @doc "The place `node` names, when the task has it, else `nil`."
  @spec chosen(Task.t(), String.t() | nil) :: String.t() | nil
  def chosen(%Task{} = task, node) when node in @nodes do
    cond do
      node == "entrega" and not PipelineView.delivers_pr?(task) -> nil
      node == "corrigir" and Task.active?(task) -> nil
      true -> node
    end
  end

  def chosen(_task, _node), do: nil

  # The tabs of a place's drawer.
  @spec tabs(String.t(), Task.t(), map(), list()) :: [{String.t(), String.t(), String.t()}]
  defp tabs("entrada", _task, _files, _changed),
    do: [
      {"pedido", "Pedido", "hero-document-text"},
      {"projeto", "Projeto", "hero-folder"}
    ]

  defp tabs("entrega", _task, _files, changed),
    do: [
      {"arquivos", "Arquivos (#{length(changed)})", "hero-document-duplicate"},
      {"merge", "Merge", "hero-arrows-pointing-in"}
    ]

  defp tabs("fim", task, files, changed) do
    attached = files |> Map.values() |> Enum.concat() |> length()

    [
      {"resumo", "Resumo", "hero-information-circle"},
      {"anexos", "Anexos (#{attached})", "hero-paper-clip"},
      not PipelineView.delivers_pr?(task) &&
        {"arquivos", "Arquivos (#{length(changed)})", "hero-document-duplicate"}
    ]
    |> Enum.filter(& &1)
  end

  defp tabs("corrigir", _task, _files, _changed), do: [{"corrigir", "Corrigir", "hero-plus"}]

  attr :node, :string, required: true
  attr :tab, :string, default: nil
  attr :task, Task, required: true
  attr :slug, :string, required: true
  attr :cost, :any, required: true
  attr :files, :map, required: true, doc: "the files sent, by stage run id"
  attr :changed_files, :list, required: true
  attr :online, :any, required: true
  attr :correct_form, Phoenix.HTML.Form, required: true
  attr :runner_choices, :list, required: true

  @doc "The drawer."
  @spec node_panel(map()) :: Phoenix.LiveView.Rendered.t()
  def node_panel(assigns) do
    tabs = tabs(assigns.node, assigns.task, assigns.files, assigns.changed_files)
    assigns = assign(assigns, tabs: tabs, tab: chosen_tab(tabs, assigns.tab))

    ~H"""
    <.side_panel id="task-node-panel" title={title(@node)} open testid="task-node-panel">
      <.drawer_tabs tabs={@tabs} active={@tab} testid="task-node" />

      <%= case @node do %>
        <% "entrada" -> %>
          <.tab_panel id="pedido" active={@tab} testid="task-node">
            <.request task={@task} />
          </.tab_panel>
          <.tab_panel id="projeto" active={@tab} testid="task-node">
            <.where task={@task} slug={@slug} />
          </.tab_panel>
        <% "entrega" -> %>
          <.tab_panel id="arquivos" active={@tab} testid="task-node">
            <.changed files={@changed_files} />
          </.tab_panel>
          <.tab_panel id="merge" active={@tab} testid="task-node">
            <.merge task={@task} />
          </.tab_panel>
        <% "fim" -> %>
          <.tab_panel id="resumo" active={@tab} testid="task-node">
            <.outcome task={@task} cost={@cost} />
          </.tab_panel>
          <.tab_panel id="anexos" active={@tab} testid="task-node">
            <.attachments task={@task} files={@files} slug={@slug} />
          </.tab_panel>
          <.tab_panel id="arquivos" active={@tab} testid="task-node">
            <.changed files={@changed_files} />
          </.tab_panel>
        <% "corrigir" -> %>
          <PipelineView.correction
            task={@task}
            online={@online}
            form={@correct_form}
            runner_choices={@runner_choices}
          />
      <% end %>
    </.side_panel>
    """
  end

  defp title("entrada"), do: "Entrada"
  defp title("entrega"), do: "Pull request"
  defp title("fim"), do: "Fim"
  defp title("corrigir"), do: "Corrigir com um prompt"

  attr :task, Task, required: true

  # The prompt the task was given, rendered.
  defp request(assigns) do
    ~H"""
    <div
      id="task-prompt-text"
      phx-hook="Highlight"
      class="prose prose-sm max-w-none dark:prose-invert prose-h1:text-lg prose-h2:text-base prose-h3:text-sm"
      data-testid="task-prompt-text"
    >
      {Markdown.to_html(@task.prompt)}
    </div>
    """
  end

  attr :task, Task, required: true
  attr :slug, :string, required: true

  # The pipeline, the project, where it runs, the worktree and the issue; the
  # project as it was when the task started.
  defp where(assigns) do
    ~H"""
    <dl class="grid gap-5 text-sm sm:grid-cols-2">
      <div>
        <dt class="text-gray-500 dark:text-gray-400">Pipeline</dt>
        <dd class="text-gray-900 dark:text-white" data-testid="task-pipeline-name">
          {@task.pipeline_name} · v{@task.pipeline_version} · {stage_progress(@task)}
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
          <span :if={!@task.project_id}>{(@task.project || %{})["name"] || "sem projeto"}</span>
        </dd>
        <dd class="font-mono text-xs text-gray-500 dark:text-gray-400" data-testid="task-where">
          {if @task.runner, do: @task.runner.name, else: "—"}:{@task.directory}
        </dd>
      </div>
      <div>
        <dt class="text-gray-500 dark:text-gray-400">Branch</dt>
        <dd class="font-mono text-xs text-gray-900 dark:text-white" data-testid="task-branch">
          {@task.branch || "— (diretório sem git)"}
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
      <div :if={@task.source_url}>
        <dt class="text-gray-500 dark:text-gray-400">Issue</dt>
        <dd class="text-xs">
          <a
            href={@task.source_url}
            target="_blank"
            rel="noopener"
            class="text-primary-600 hover:underline dark:text-primary-400"
            data-testid="task-issue"
          >
            {IntegrationComponents.issue_label(@task.source_url)}
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
    </dl>
    <div
      :if={@task.project}
      class="mt-6 border-t border-gray-100 pt-4 text-sm dark:border-gray-800"
      data-testid="task-project-snapshot"
    >
      <p class="text-gray-500 dark:text-gray-400">Retrato do projeto quando a tarefa começou</p>
      <dl class="mt-2 grid gap-x-6 gap-y-2 sm:grid-cols-2">
        <div :for={
          {label, value} <- [
            {"Setup", @task.project["setup_command"]},
            {"Testes", @task.project["test_command"]},
            {"Lint", @task.project["lint_command"]},
            {"Copiar para o worktree", Enum.join(@task.project["copy_paths"] || [], ", ")}
          ]
        }>
          <dt class="text-gray-500 dark:text-gray-400">{label}</dt>
          <dd class="break-all font-mono text-xs text-gray-900 dark:text-white">
            {if value in [nil, ""], do: "—", else: value}
          </dd>
        </div>
      </dl>
    </div>
    """
  end

  defp worktree_state(%Task{worktree_removed_at: %DateTime{}}), do: "Removido do runner."

  defp worktree_state(%Task{worktree_removal_requested_at: %DateTime{}}),
    do: "Removendo: aguardando o runner."

  defp worktree_state(%Task{worktree_error: error}) when is_binary(error),
    do: "Não foi possível remover: #{error}"

  defp worktree_state(_task), do: nil

  attr :files, :list, required: true

  # The files the task changed so far, as its latest stage report tells.
  defp changed(assigns) do
    ~H"""
    <p :if={@files == []} class="text-sm text-gray-500 dark:text-gray-400" data-testid="task-no-files">
      Nenhum arquivo alterado ainda.
    </p>
    <.file_list :if={@files != []} files={@files} data-testid="task-files" />
    """
  end

  attr :task, Task, required: true

  # The pull request and why its merge stopped.
  defp merge(assigns) do
    ~H"""
    <dl class="text-sm">
      <div>
        <dt class="text-gray-500 dark:text-gray-400">Pull request</dt>
        <dd class="text-xs">
          <a
            :if={@task.pr_url}
            href={@task.pr_url}
            target="_blank"
            rel="noopener"
            class="text-primary-600 hover:underline dark:text-primary-400"
            data-testid="task-pr"
          >
            {@task.pr_url} <.icon name="hero-arrow-top-right-on-square" class="size-3" />
          </a>
          <span :if={!@task.pr_url} class="text-gray-500 dark:text-gray-400">ainda não aberto</span>
        </dd>
        <dd
          :if={@task.merge_state == "blocked" and @task.merge_reason}
          class="mt-1 text-xs text-gray-600 dark:text-gray-300"
          data-testid="task-merge-reason"
        >
          O merge parou: {@task.merge_reason}
        </dd>
      </div>
    </dl>
    """
  end

  attr :task, Task, required: true
  attr :cost, :any, required: true

  # What the task cost against its cap and how far it went.
  defp outcome(assigns) do
    ~H"""
    <dl class="grid gap-5 text-sm sm:grid-cols-2">
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
        <dt class="text-gray-500 dark:text-gray-400">Andamento</dt>
        <dd class="text-gray-900 dark:text-white" data-testid="task-progress">
          {stage_progress(@task)}
        </dd>
      </div>
    </dl>
    """
  end

  attr :task, Task, required: true
  attr :files, :map, required: true
  attr :slug, :string, required: true

  # The files each attempt sent (`$CP_FILES_DIR`), the latest attempts first.
  defp attachments(assigns) do
    ~H"""
    <div class="space-y-5">
      <p
        :if={@files == %{}}
        class="text-sm text-gray-500 dark:text-gray-400"
        data-testid="task-no-attachments"
      >
        Nenhuma etapa enviou arquivos ainda. O que o agente copia para <code>$CP_FILES_DIR</code>
        aparece aqui.
      </p>
      <section
        :for={run <- attachment_runs(@task, @files)}
        class="space-y-2"
        data-testid={"task-attachments-#{run.key}-#{run.attempt}"}
      >
        <h3 class="text-sm font-medium text-gray-700 dark:text-gray-300">
          {run.name} · tentativa {run.attempt}
        </h3>
        <.files
          files={Map.fetch!(@files, run.id)}
          workspace_slug={@slug}
          testid="task-attachment"
          key={"#{run.key}-#{run.attempt}"}
        />
      </section>
    </div>
    """
  end

  defp attachment_runs(%Task{stage_runs: runs}, files) do
    runs
    |> Enum.filter(&Map.has_key?(files, &1.id))
    |> Enum.sort_by(&{&1.index, &1.attempt}, :desc)
  end
end
