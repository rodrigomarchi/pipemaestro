defmodule PipeMaestroWeb.TaskLive.FilesTab do
  @moduledoc """
  The task's "Arquivos" tab: the files it changed so far, as its latest
  stage report tells (`PipeMaestro.Tasks.changed_files/1`).
  """
  use PipeMaestroWeb, :html

  import PipeMaestroWeb.TaskComponents, only: [file_list: 1]

  attr :files, :list, required: true, doc: "the files the task changed"

  @doc "The tab."
  @spec files(map()) :: Phoenix.LiveView.Rendered.t()
  def files(assigns) do
    ~H"""
    <.card variant="outline">
      <.card_content>
        <p
          :if={@files == []}
          class="text-sm text-gray-500 dark:text-gray-400"
          data-testid="task-no-files"
        >
          Nenhum arquivo alterado ainda.
        </p>
        <.file_list
          :if={@files != []}
          files={@files}
          data-testid="task-files"
        />
      </.card_content>
    </.card>
    """
  end
end
