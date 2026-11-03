defmodule ClaudeControlPlaneRunner.Claude do
  @moduledoc """
  How the runner invokes the agent CLI for a job: `claude -p <prompt>` in
  headless mode, printing one JSON event per line (`stream-json`), with nothing
  saved as a resumable session, and the permissions of the job's profile
  (`ClaudeControlPlaneProtocol.Job.permission_profiles/0`):

    * `"total"` (or none given): every permission granted;
    * `"edicao"`: file edits accepted; other tools only as allowed;
    * `"leitura"`: reading and searching, and writing under `.control-plane/`
      (where the stage's artifact goes); other tools only as allowed.

  Nobody answers a permission prompt in a headless run, so anything not
  allowed is denied.

  `$CLAUDE_BIN` points to another executable (tests use a fake that prints the
  same kind of lines).

  The CLI signs in as whoever is logged in to it on this machine, unless the
  runner has its own API key: `$RUNNER_ANTHROPIC_API_KEY`, handed to the CLI
  as `ANTHROPIC_API_KEY` and never sent to the control plane.
  """

  alias ClaudeControlPlaneProtocol.Job

  @api_key_env "RUNNER_ANTHROPIC_API_KEY"

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
      "--verbose"
    ] ++
      permissions(job.permissions) ++
      ["--no-session-persistence", "--include-partial-messages"] ++ optional(job)
  end

  @read_tools ~w(Read Grep Glob LS TodoWrite WebSearch WebFetch)
  # An Edit rule covers every file-editing tool, Write included.
  @artifact_rules ["Edit(./.control-plane/**)"]

  defp permissions(nil), do: ["--dangerously-skip-permissions"]
  defp permissions(%{"profile" => "total"}), do: ["--dangerously-skip-permissions"]

  defp permissions(%{"profile" => "edicao"} = permissions),
    do: restricted("acceptEdits", permissions["allow"] || [], permissions["deny"] || [])

  defp permissions(%{"profile" => "leitura"} = permissions) do
    allow = @read_tools ++ @artifact_rules ++ (permissions["allow"] || [])
    restricted("dontAsk", allow, permissions["deny"] || [])
  end

  defp restricted(mode, allow, deny) do
    ["--permission-mode", mode, "--permission-prompts", "none"] ++
      tool_flag("--allowedTools", allow) ++ tool_flag("--disallowedTools", deny)
  end

  # One argument per rule: a rule may hold spaces ("Bash(mix test:*)"). The
  # option takes values until the next flag.
  defp tool_flag(_flag, []), do: []
  defp tool_flag(flag, rules), do: [flag | rules]

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

    api_key =
      case System.get_env(@api_key_env) do
        key when key in [nil, ""] -> []
        key -> [{~c"ANTHROPIC_API_KEY", String.to_charlist(key)}]
      end

    [{~c"CLAUDECODE", false}, {~c"CLAUDE_CODE_ENTRYPOINT", false} | artifact ++ api_key]
  end

  @doc "The runner's own API key for the CLI, if it has one."
  @spec api_key() :: String.t() | nil
  def api_key, do: System.get_env(@api_key_env)

  @doc """
  What the runner announces about the agent (`ClaudeControlPlaneProtocol.Hello`
  `agent`): the CLI's version (asked to `executable`) and whether it uses the
  runner's API key (`api_key`, by default `$RUNNER_ANTHROPIC_API_KEY`) or the
  machine's login.
  """
  @spec agent({:ok, Path.t()} | {:error, :not_found}, String.t() | nil) ::
          %{String.t() => String.t() | nil}
  def agent(executable, api_key \\ api_key()) do
    %{
      "cli_version" => cli_version(executable),
      "auth" => if(api_key in [nil, ""], do: "login", else: "api_key")
    }
  end

  defp cli_version({:ok, path}) do
    case System.cmd(path, ["--version"], stderr_to_stdout: true) do
      {output, 0} -> output |> String.split() |> List.first()
      _failed -> nil
    end
  rescue
    _error in ErlangError -> nil
  end

  defp cli_version(_not_found), do: nil
end
