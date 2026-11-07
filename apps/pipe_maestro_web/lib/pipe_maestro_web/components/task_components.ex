defmodule PipeMaestroWeb.TaskComponents do
  @moduledoc """
  Pieces every task screen shares: statuses, the stage progress and what a
  stage changed in the task's directory.
  """
  use PipeMaestroWeb, :html

  import PipeMaestroWeb.JobComponents, only: [patch: 1]
  import PipeMaestroWeb.PipelineComponents, only: [pipeline_diagram: 1]

  alias PipeMaestro.Jobs.Job
  alias PipeMaestro.Tasks.{StageRun, Task}
  alias PipeMaestroWeb.PipelineDiagram

  @doc "The task's status as a badge."
  attr :task, Task, required: true
  attr :rest, :global

  @spec task_status(map()) :: Phoenix.LiveView.Rendered.t()
  def task_status(assigns) do
    {label, color} = task_label(assigns.task.status)
    assigns = assign(assigns, label: label, color: color)

    ~H"""
    <.badge size="sm" variant="soft" color={@color} dot label={@label} {@rest} />
    """
  end

  defp task_label(:queued), do: {"Na fila", "gray"}
  defp task_label(:running), do: {"Executando", "info"}
  defp task_label(:awaiting_decision), do: {"Aguardando decisão", "warning"}
  defp task_label(:succeeded), do: {"Concluída", "success"}
  defp task_label(:failed), do: {"Falhou", "danger"}
  defp task_label(:canceled), do: {"Cancelada", "gray"}

  @doc "A stage attempt's status as a badge."
  attr :run, StageRun, required: true
  attr :rest, :global

  @spec stage_run_status(map()) :: Phoenix.LiveView.Rendered.t()
  def stage_run_status(assigns) do
    {label, color} = stage_label(assigns.run.status)
    assigns = assign(assigns, label: label, color: color)

    ~H"""
    <.badge size="xs" variant="soft" color={@color} label={@label} {@rest} />
    """
  end

  @doc """
  How an attempt that asked to continue the stage before started: in that
  session, or from scratch when the runner no longer had it. Nothing for an
  attempt that did not ask. Needs the run's `job`.
  """
  attr :run, StageRun, required: true

  @spec stage_run_session(map()) :: Phoenix.LiveView.Rendered.t()
  def stage_run_session(assigns) do
    assigns = assign(assigns, :resumed, session_resumed(assigns.run.job))

    ~H"""
    <.badge
      :if={@resumed != :none}
      size="xs"
      variant="soft"
      color={if @resumed == :fell_back, do: "warning", else: "gray"}
      label={
        if @resumed == :fell_back,
          do: "Começou do zero: a sessão anterior não estava disponível",
          else: "Continuou a etapa anterior"
      }
      data-testid={"stage-run-session-#{@run.key}-#{@run.attempt}"}
    />
    """
  end

  defp session_resumed(%Job{context: %{"resume_session_id" => id}} = job) when is_binary(id),
    do: if(job.session_resumed == false, do: :fell_back, else: :resumed)

  defp session_resumed(_job), do: :none

  defp stage_label(:running), do: {"Executando", "info"}
  defp stage_label(:passed), do: {"Aprovada no gate", "success"}
  defp stage_label(:failed), do: {"Falhou", "danger"}
  defp stage_label(:blocked), do: {"Bloqueada", "warning"}
  defp stage_label(:canceled), do: {"Cancelada", "gray"}
  defp stage_label(:lost), do: {"Perdida (runner)", "warning"}

  @doc "Where the task is: `2/6 · Investigação`, or how it ended."
  @spec stage_progress(Task.t()) :: String.t()
  def stage_progress(%Task{status: status} = task)
      when status in [:running, :awaiting_decision] do
    "#{task.current_stage + 1}/#{length(task.stages)} · #{Task.current(task).name}"
  end

  def stage_progress(%Task{stages: [_one]}), do: "1 etapa"
  def stage_progress(%Task{} = task), do: "#{length(task.stages)} etapas"

  @doc """
  Where a task is, at a glance: a dot per stage of its pipeline with the
  stage's state (`PipeMaestroWeb.PipelineDiagram.task_states/1`, a group's
  stacked), and `stage_progress/1`. Needs the task's `stage_runs`.
  """
  attr :task, Task, required: true
  attr :testid, :string, required: true
  attr :class, :any, default: nil

  @spec task_progress(map()) :: Phoenix.LiveView.Rendered.t()
  def task_progress(assigns) do
    assigns =
      assign(assigns,
        diagram:
          PipelineDiagram.build(PipelineDiagram.for_task(assigns.task),
            states: PipelineDiagram.task_states(assigns.task)
          )
      )

    ~H"""
    <span class={["flex min-w-0 items-center gap-2", @class]} data-testid={@testid}>
      <.pipeline_diagram diagram={@diagram} mode={:micro} testid={"#{@testid}-diagram"} />
      <span class="truncate">{stage_progress(@task)}</span>
    </span>
    """
  end

  @doc """
  The files a stage changed (`changes` as the runner reports it): a summary
  that opens to the files and the patch, its lines colored.
  """
  attr :changes, :map, required: true
  attr :id, :string, required: true, doc: "suffix for the test ids (`<key>-<attempt>`)"

  @spec changes_report(map()) :: Phoenix.LiveView.Rendered.t()
  def changes_report(assigns) do
    files = assigns.changes["files"] || []

    assigns =
      assign(assigns,
        files: files,
        added: files |> Enum.map(&(&1["added"] || 0)) |> Enum.sum(),
        removed: files |> Enum.map(&(&1["removed"] || 0)) |> Enum.sum()
      )

    ~H"""
    <details
      class="rounded-lg border border-gray-200 text-sm dark:border-gray-800"
      data-testid={"stage-run-changes-#{@id}"}
    >
      <summary
        class="cursor-pointer px-3 py-2 text-gray-700 dark:text-gray-300"
        data-testid={"stage-run-changes-summary-#{@id}"}
      >
        <.icon name="hero-document-text" class="size-4" />
        {files_label(length(@files))}
        <span class="ml-1 font-mono text-xs text-success-700 dark:text-success-400">+{@added}</span>
        <span class="font-mono text-xs text-danger-700 dark:text-danger-400">−{@removed}</span>
      </summary>
      <div class="border-t border-gray-200 px-3 py-2 dark:border-gray-800">
        <.file_list files={@files} />
        <p :if={@changes["truncated"]} class="mt-2 text-xs text-warning-700 dark:text-warning-400">
          O diff é grande: o patch foi cortado.
        </p>
        <.patch
          :if={@changes["patch"] not in [nil, ""]}
          patch={@changes["patch"]}
          data-testid={"stage-run-patch-#{@id}"}
        />
      </div>
    </details>
    """
  end

  @doc """
  Changed files with lines added and removed; a binary file says so, and a
  file of a directory without git says whether it is new, modified or removed.
  """
  attr :files, :list, required: true
  attr :rest, :global

  @spec file_list(map()) :: Phoenix.LiveView.Rendered.t()
  def file_list(assigns) do
    ~H"""
    <ul class="space-y-0.5 font-mono text-xs" {@rest}>
      <li :for={file <- @files} class="flex gap-3">
        <span :if={file["added"]} class="w-20 shrink-0 text-right">
          <span class="text-success-700 dark:text-success-400">+{file["added"]}</span>
          <span class="text-danger-700 dark:text-danger-400">−{file["removed"]}</span>
        </span>
        <span :if={!file["added"]} class="w-20 shrink-0 text-right text-gray-500">
          {file_state(file["status"])}
        </span>
        <span class="break-all text-gray-800 dark:text-gray-200">{file["path"]}</span>
      </li>
    </ul>
    """
  end

  # Outside git a file has no lines, only what happened to it.
  defp file_state("new"), do: "novo"
  defp file_state("modified"), do: "alterado"
  defp file_state("removed"), do: "removido"
  defp file_state(_binary), do: "binário"

  defp files_label(1), do: "1 arquivo alterado"
  defp files_label(n), do: "#{n} arquivos alterados"
end
