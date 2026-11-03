defmodule ClaudeControlPlaneRunner.Claude do
  @moduledoc """
  How the runner invokes the agent CLI for a job: `claude -p <prompt>` in
  headless mode, printing one JSON event per line (`stream-json`), with every
  permission granted and nothing saved as a resumable session.

  `$CLAUDE_BIN` points to another executable (tests use a fake that prints the
  same kind of lines).
  """

  @doc "The arguments for running `prompt`."
  @spec argv(String.t()) :: [String.t()]
  def argv(prompt) do
    [
      "-p",
      prompt,
      "--output-format",
      "stream-json",
      "--verbose",
      "--dangerously-skip-permissions",
      "--no-session-persistence"
    ]
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
  Environment changes for the CLI's process. A runner started from inside an
  agent session would otherwise make the CLI refuse to run, nested.
  """
  @spec env() :: [{charlist(), charlist() | false}]
  def env, do: [{~c"CLAUDECODE", false}, {~c"CLAUDE_CODE_ENTRYPOINT", false}]
end
