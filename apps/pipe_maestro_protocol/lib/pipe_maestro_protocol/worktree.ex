defmodule PipeMaestroProtocol.Worktree do
  @moduledoc """
  The messages about a runner's task worktrees (`PipeMaestroProtocol.Job`
  `worktree`) on the runner's channel.

  Control plane → runner:

    * `"worktree:remove"` — `%{"task_id", "directory"}`: remove the task's
      worktree (its branch stays in the directory's repository). Sent only for
      a task that has ended, and again on every join until done.

  Runner → control plane:

    * `"worktree:removed"` — `%{"task_id"}`, plus `"error"` when it could not.
    * `"worktree:usage"` — `%{"count", "bytes", "free_bytes"}`: how many
      worktrees the runner keeps, the space they take and the space left on
      their disk (`nil` when unknown). Sent after joining and every few
      minutes while it changes.
  """

  alias PipeMaestroProtocol.Hello

  @task_id_format ~r/^[A-Za-z0-9_-]{1,64}$/

  @doc "The control plane asks the runner to remove a task's worktree."
  @spec remove_event() :: String.t()
  def remove_event, do: "worktree:remove"

  @doc "The runner removed a task's worktree (or could not)."
  @spec removed_event() :: String.t()
  def removed_event, do: "worktree:removed"

  @doc "The runner reports the space its worktrees take."
  @spec usage_event() :: String.t()
  def usage_event, do: "worktree:usage"

  @doc "Validates a removal request."
  @spec parse_remove(term()) :: {:ok, map()} | {:error, String.t()}
  def parse_remove(%{"task_id" => task_id, "directory" => directory} = payload)
      when is_binary(task_id) do
    if task_id =~ @task_id_format and Hello.valid_directory_name?(directory),
      do: {:ok, Map.take(payload, ["task_id", "directory"])},
      else: {:error, "task_id and directory must be a task id and a directory name"}
  end

  def parse_remove(_payload), do: {:error, "a removal needs a task_id and a directory"}

  @doc "Validates a usage report."
  @spec parse_usage(term()) :: {:ok, map()} | {:error, String.t()}
  def parse_usage(%{"count" => count, "bytes" => bytes} = payload)
      when is_integer(count) and count >= 0 and is_integer(bytes) and bytes >= 0 do
    case Map.get(payload, "free_bytes") do
      free when is_nil(free) or (is_integer(free) and free >= 0) ->
        {:ok, %{"count" => count, "bytes" => bytes, "free_bytes" => free}}

      _other ->
        {:error, "free_bytes must be a number of bytes"}
    end
  end

  def parse_usage(_payload), do: {:error, "usage needs a count and bytes"}
end
