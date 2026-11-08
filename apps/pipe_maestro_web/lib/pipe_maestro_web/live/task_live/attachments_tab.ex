defmodule PipeMaestroWeb.TaskLive.AttachmentsTab do
  @moduledoc """
  The task's "Anexos" tab: the files each attempt sent
  (`$CP_FILES_DIR`), the latest attempts first.
  """
  use PipeMaestroWeb, :html

  import PipeMaestroWeb.JobFileComponents, only: [files: 1]

  alias PipeMaestro.Tasks.Task

  attr :task, Task, required: true
  attr :files, :map, required: true, doc: "the files sent, by stage run id"
  attr :slug, :string, required: true

  @doc "The tab."
  @spec attachments(map()) :: Phoenix.LiveView.Rendered.t()
  def attachments(assigns) do
    ~H"""
    <.card variant="outline">
      <.card_content class="space-y-5">
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
      </.card_content>
    </.card>
    """
  end

  # The attempts that sent files, the latest first.
  defp attachment_runs(%Task{stage_runs: runs}, files) do
    runs
    |> Enum.filter(&Map.has_key?(files, &1.id))
    |> Enum.sort_by(&{&1.index, &1.attempt}, :desc)
  end
end
