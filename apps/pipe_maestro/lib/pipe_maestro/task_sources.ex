defmodule PipeMaestro.TaskSources do
  @moduledoc """
  Where tasks come from, apart from where their code lives (ADR 0053).

  A task source (`PipeMaestro.TaskSources.Source`) is registered under a key
  in the configuration:

      config :pipe_maestro, PipeMaestro.TaskSources,
        sources: %{"git_issue" => PipeMaestro.Integrations.IssueSource}

  The task engine (`PipeMaestro.Tasks`) and the proposals know only what is
  here: an item read on a source (`PipeMaestro.TaskSources.Item`) becomes a
  task or a triage on the project and pipeline its trigger says (`start/3`),
  the task keeps its origin (`PipeMaestro.TaskSources.Origin`), and what the
  source does with the task's work goes through these functions to the
  source of the task. A task without a source, or of a source no longer
  registered, gets nothing of them.
  """

  alias PipeMaestro.Accounts.User
  alias PipeMaestro.Jobs.Job
  alias PipeMaestro.{Proposals, Repo, Tasks}
  alias PipeMaestro.Tasks.Task
  alias PipeMaestro.TaskSources.{Commands, Item, Origin}
  alias PipeMaestro.Workspaces.Workspace

  @typedoc """
  What a trigger of a source says of the work: `mode` `"task"` (straight to
  the pipeline) or `"triage"` (the agent writes the task first, created on
  its own with `auto_approve`), on which project and pipeline, on whose
  behalf (`acting_user_id`).
  """
  @type target :: %{
          required(:mode) => String.t(),
          required(:project_id) => Ecto.UUID.t() | nil,
          required(:pipeline_id) => Ecto.UUID.t() | nil,
          required(:acting_user_id) => Ecto.UUID.t() | nil,
          optional(:auto_approve) => boolean()
        }

  @doc "The registered sources, by key."
  @spec sources() :: %{String.t() => module()}
  def sources, do: Application.get_env(:pipe_maestro, __MODULE__, [])[:sources] || %{}

  @doc "The source registered under `key`."
  @spec fetch(String.t() | nil) :: {:ok, module()} | :error
  def fetch(key) when is_binary(key), do: Map.fetch(sources(), key)
  def fetch(_key), do: :error

  @doc "Takes a webhook delivery for the source under `source` (`c:Source.receive_webhook/4`)."
  @spec receive_webhook(String.t(), String.t() | nil, map(), binary(), keyword()) ::
          {:ok, term()} | :duplicate | {:error, atom()}
  def receive_webhook(source, key, headers, raw_body, opts \\ []) do
    with {:ok, module} <- source_with(source, :receive_webhook, 4) do
      module.receive_webhook(key, headers, raw_body, opts)
    end
  end

  defp source_with(source, function, arity) do
    with {:ok, module} <- fetch(source),
         true <- Code.ensure_loaded?(module) and function_exported?(module, function, arity) do
      {:ok, module}
    else
      _none -> {:error, :not_found}
    end
  end

  @doc """
  Starts the work on `item`, as its trigger says (`t:target/0`): a task
  (`PipeMaestro.Tasks.create_from_item/3`) or a triage
  (`PipeMaestro.Proposals.triage_item/3`).
  """
  @spec start(Workspace.t(), Item.t(), target()) ::
          {:ok, Task.t() | Job.t()}
          | {:error, Ecto.Changeset.t() | :no_acting_user | :already_triaging}
  def start(%Workspace{} = workspace, %Item{} = item, %{mode: "task"} = target),
    do: Tasks.create_from_item(workspace, item, target)

  def start(%Workspace{} = workspace, %Item{} = item, %{mode: "triage"} = target),
    do: Proposals.triage_item(workspace, item, target)

  @doc "Whether the item `external_id` of `source` has a task or a triage going on."
  @spec active?(Workspace.t(), String.t(), String.t()) :: boolean()
  def active?(%Workspace{} = workspace, source, external_id) do
    Tasks.active_for_source?(workspace, source, external_id) or
      Proposals.triaging?(workspace, source, external_id)
  end

  @doc """
  The origin of a link a person pasted on a task: the first source that
  recognizes it, or the message of the first that refuses it.
  """
  @spec parse_link(String.t()) :: {:ok, Origin.t()} | {:error, String.t()}
  def parse_link(url) when is_binary(url) do
    sources()
    |> Enum.sort()
    |> Enum.filter(fn {key, _module} -> match?({:ok, _}, source_with(key, :parse_link, 1)) end)
    |> Enum.reduce_while({:error, nil}, fn {_key, module}, {:error, first} ->
      case module.parse_link(url) do
        {:ok, origin} -> {:halt, {:ok, origin}}
        {:error, message} -> {:cont, {:error, first || message}}
      end
    end)
    |> case do
      {:error, nil} -> {:error, "o link não é de uma origem conhecida"}
      result -> result
    end
  end

  @doc "Reflects a change of `task` on its source."
  @spec task_changed(Task.t()) :: :ok
  def task_changed(%Task{} = task) do
    case fetch(task.source) do
      {:ok, module} -> module.task_changed(task)
      :error -> :ok
    end
  end

  @doc "Tells the source of a triage how it ended (`c:Source.triage_finished/1`)."
  @spec triage_finished(Job.t()) :: :ok
  def triage_finished(%Job{} = job) do
    origin = Origin.from_input(get_in(job.context || %{}, ["proposal", "input"]))

    case origin && fetch(origin.source) do
      {:ok, module} -> module.triage_finished(job)
      _none -> :ok
    end
  end

  @doc "What the runner delivers for the source of `task` with a stage (`%{}` without one)."
  @spec runner_delivery(Task.t()) :: map()
  def runner_delivery(%Task{} = task) do
    case fetch(task.source) do
      {:ok, module} -> module.runner_delivery(task)
      :error -> %{}
    end
  end

  @doc "The line of the task's pull request that names its origin, if any."
  @spec pr_reference(Task.t()) :: String.t() | nil
  def pr_reference(%Task{} = task) do
    case fetch(task.source) do
      {:ok, module} -> module.pr_reference(task)
      :error -> nil
    end
  end

  @doc """
  Applies a command a person wrote on the task's source
  (`PipeMaestro.TaskSources.Commands`) with the same functions as the
  screen, on behalf of the task's owner; `via` names who wrote it, for the
  audit. A command that does not apply now gives the reason, for the source
  to answer.
  """
  @spec apply_command(Task.t(), Commands.t(), keyword()) :: {:ok, Task.t()} | {:error, String.t()}
  def apply_command(%Task{} = task, command, opts) do
    case run(task, command, owner(task), opts[:via]) do
      {:ok, task} -> {:ok, task}
      error -> {:error, reason(error)}
    end
  end

  defp run(task, %{action: :advance, text: text}, by, via),
    do: Tasks.advance(task, blank(text), by: by, via: via)

  defp run(task, %{action: :retry, text: text}, by, via),
    do: Tasks.retry_stage(task, blank(text), by: by, via: via)

  defp run(task, %{action: :pause}, _by, _via), do: Tasks.request_pause(task)
  defp run(task, %{action: :cancel}, by, via), do: Tasks.cancel_task(task, by: by, via: via)

  defp run(task, %{action: :correct, text: text}, by, via),
    do: Tasks.correct(task, blank(text), by: by, via: via)

  defp run(task, %{action: :answer, text: text}, by, via) do
    questions = get_in(task.decision_questionnaire || %{}, ["perguntas"]) || []
    Tasks.answer(task, Commands.answers(text, questions), nil, by: by, via: via)
  end

  @doc "The person a task belongs to: who acts for it when its source sends a command."
  @spec owner(Task.t()) :: User.t() | nil
  def owner(%Task{created_by_user_id: id}), do: Repo.get(User, id)

  defp blank(text), do: if(String.trim(text) == "", do: nil, else: text)

  defp reason({:error, :invalid_answers, message}), do: "As respostas não valem: #{message}"
  defp reason({:error, :not_awaiting}), do: "A tarefa não espera uma decisão agora."
  defp reason({:error, :not_running}), do: "A tarefa não está rodando."
  defp reason({:error, :finished}), do: "A tarefa já terminou."

  defp reason({:error, :active}),
    do: "A tarefa ainda está em andamento; corrija quando ela terminar."

  defp reason({:error, :blank}), do: "Diga o que corrigir depois do comando."
  defp reason({:error, other}), do: "Não foi possível (#{inspect(other)})."
end
