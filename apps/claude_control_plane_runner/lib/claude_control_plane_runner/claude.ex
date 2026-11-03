defmodule ClaudeControlPlaneRunner.Claude do
  @moduledoc """
  How the runner invokes the agent CLI for a job: `claude -p <prompt>` in
  headless mode, printing one JSON event per line (`stream-json`), with every
  permission granted and nothing saved as a resumable session.

  `$CLAUDE_BIN` points to another executable (tests use a fake that prints the
  same kind of lines).
  """

  alias ClaudeControlPlaneProtocol.Job

  @doc """
  The arguments for running `job`: its prompt, plus its output schema
  (`--json-schema`), model and budget when it has them.
  """
  @spec argv(Job.t()) :: [String.t()]
  def argv(%Job{} = job) do
    [
      "-p",
      job.prompt,
      "--output-format",
      "stream-json",
      "--verbose",
      "--dangerously-skip-permissions",
      "--no-session-persistence"
    ] ++ optional(job)
  end

  defp optional(job) do
    Enum.flat_map(
      [
        {"--json-schema", job.output_schema && Jason.encode!(job.output_schema)},
        {"--model", job.model},
        {"--max-budget-usd", job.max_budget_usd && to_string(job.max_budget_usd)}
      ],
      fn
        {_flag, nil} -> []
        {flag, value} -> [flag, value]
      end
    )
  end

  @doc "The CLI's path: `$CLAUDE_BIN`, or `claude` found on the PATH."
  @spec executable() :: {:ok, Path.t()} | {:error, :not_found}
  def executable do
    case System.get_env("CLAUDE_BIN") || System.find_executable("claude") do
      nil -> {:error, :not_found}
      path -> if File.regular?(path), do: {:ok, path}, else: {:error, :not_found}
    end
  end

  @doc """
  Environment changes for `job`'s CLI process. The nested-session markers are
  removed (a runner started from inside an agent session would otherwise make
  the CLI refuse to run), and `CP_ARTIFACT_PATH` tells hooks and scripts where
  the stage's artifact goes.
  """
  @spec env(Job.t()) :: [{charlist(), charlist() | false}]
  def env(%Job{} = job) do
    artifact =
      if job.artifact_path,
        do: [{~c"CP_ARTIFACT_PATH", String.to_charlist(job.artifact_path)}],
        else: []

    [{~c"CLAUDECODE", false}, {~c"CLAUDE_CODE_ENTRYPOINT", false} | artifact]
  end
end
