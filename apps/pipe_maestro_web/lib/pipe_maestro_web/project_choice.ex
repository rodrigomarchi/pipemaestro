defmodule PipeMaestroWeb.ProjectChoice do
  @moduledoc """
  The project select of every form that starts work (a task, a job on its
  own, a proposal): each project of the workspace as an option, disabled with
  the reason when it cannot take that work now, and the runner a chosen
  project waits for while it is offline.
  """

  alias PipeMaestro.{Jobs, Projects}
  alias PipeMaestro.Projects.Project

  @typedoc "What the work needs: a task, or a disposable worktree (a job or a proposal)."
  @type need :: :task | :scratch

  @doc "The select's options for `projects`, given the ids of the runners online."
  @spec options([Project.t()], MapSet.t(), need()) :: [keyword()]
  def options(projects, online_runner_ids, need) do
    for project <- projects do
      case reason(project, online_runner_ids, need) do
        nil -> [key: label(project), value: project.id]
        reason -> [key: "#{project.name} (#{reason})", value: project.id, disabled: true]
      end
    end
  end

  @doc "Why `project` cannot take the work now, or `nil` (an offline runner is no reason)."
  @spec reason(Project.t(), MapSet.t(), need()) :: String.t() | nil
  def reason(project, online_runner_ids, need) do
    case {Projects.health(project, online_runner_ids), need} do
      {:needs_runner, _need} -> "precisa de um runner"
      {:directory_gone, _need} -> "o runner não oferece mais a pasta"
      {_ok_or_offline, :task} -> nil
      {_ok_or_offline, :scratch} -> scratch_reason(project)
    end
  end

  defp scratch_reason(project) do
    case Jobs.project_ready(project) do
      :ok -> nil
      {:error, reason} -> reason
    end
  end

  @doc """
  The name of the runner the project `project_id` (among `projects`) waits
  for, when it is offline; `nil` otherwise.
  """
  @spec offline_runner([Project.t()], MapSet.t(), term()) :: String.t() | nil
  def offline_runner(projects, online_runner_ids, project_id) do
    case Enum.find(projects, &(&1.id == project_id)) do
      %Project{} = project ->
        if Projects.health(project, online_runner_ids) == :runner_offline,
          do: project.runner.name

      nil ->
        nil
    end
  end

  defp label(%Project{} = project),
    do: "#{project.name} · #{project.runner.name}:#{project.directory}"
end
