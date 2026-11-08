defmodule PipeMaestroWeb.TaskLive.RequestTab do
  @moduledoc """
  The task's "Pedido" tab: the prompt it was given, rendered, and the
  project as it was when the task started.
  """
  use PipeMaestroWeb, :html

  alias PipeMaestro.Tasks.Task
  alias PipeMaestroWeb.Markdown

  attr :task, Task, required: true

  @doc "The tab."
  @spec request(map()) :: Phoenix.LiveView.Rendered.t()
  def request(assigns) do
    ~H"""
    <.card variant="outline">
      <.card_content>
        <div
          id="task-prompt-text"
          phx-hook="Highlight"
          class="prose prose-sm max-w-none dark:prose-invert prose-h1:text-lg prose-h2:text-base prose-h3:text-sm"
          data-testid="task-prompt-text"
        >
          {Markdown.to_html(@task.prompt)}
        </div>
        <details
          :if={@task.project}
          id="task-project-snapshot"
          class="mt-4 border-t border-gray-100 pt-4 text-sm dark:border-gray-800"
          data-testid="task-project-snapshot"
          phx-mounted={JS.ignore_attributes(["open"])}
        >
          <summary class="cursor-pointer text-gray-500 dark:text-gray-400">
            Retrato do projeto quando a tarefa começou
          </summary>
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
        </details>
      </.card_content>
    </.card>
    """
  end
end
