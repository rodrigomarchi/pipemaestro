defmodule PipeMaestroRunner.Claude do
  @moduledoc """
  How the runner invokes the agent CLI for a job: `claude -p <prompt>` in
  headless mode, printing one JSON event per line (`stream-json`), and every
  permission granted: pipelines run
  on their own, and nobody would answer a permission prompt in a headless run.

  The CLI saves no resumable session, unless the job keeps it for the next
  stage (`persist_session`) or resumes an earlier one (`resume_session_id`,
  forked so the earlier session stays as it was: ADR 0041).

  `$CLAUDE_BIN` points to another executable (tests use a fake that prints the
  same kind of lines).

  The CLI signs in as whoever is logged in to it on this machine, unless the
  runner has its own API key: `$RUNNER_ANTHROPIC_API_KEY`, handed to the CLI
  as `ANTHROPIC_API_KEY` and never sent to the control plane.
  """

  alias PipeMaestroProtocol.Job

  @api_key_env "RUNNER_ANTHROPIC_API_KEY"

  @doc """
  The arguments for running `job`: its prompt, plus its output schema
  (`--json-schema`), model, budget, system prompt, MCP servers and agents
  when it has them.
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
      ["--dangerously-skip-permissions"] ++
      session(job) ++ ["--include-partial-messages"] ++ optional(job)
  end

  defp session(%Job{resume_session_id: id}) when is_binary(id),
    do: ["--resume", id, "--fork-session"]

  defp session(%Job{persist_session: true}), do: []
  defp session(_job), do: ["--no-session-persistence"]

  defp optional(job) do
    Enum.flat_map(
      [
        {"--json-schema", job.output_schema && JSON.encode!(job.output_schema)},
        {"--model", job.model},
        {"--max-budget-usd", job.max_budget_usd && to_string(job.max_budget_usd)},
        {"--append-system-prompt", job.system_prompt},
        {"--mcp-config", job.mcp_config && JSON.encode!(job.mcp_config)},
        {"--agents", job.agents && JSON.encode!(job.agents)},
        {"--agent", job.agent}
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
  Environment changes for `job`'s CLI process: the workspace's secrets the
  job carries (`env`), never written anywhere. The nested-session markers are
  removed (a runner started from inside an agent session would otherwise make
  the CLI refuse to run), and so is Burrito's `__BURRITO` (with it, any Elixir
  VM the agent starts that loads the runner app would boot as the runner's CLI).
  `CP_ARTIFACT_PATH` tells hooks and scripts where the stage's artifact goes,
  and is unset for a job without one, so the runner's own never leaks in. With a
  `telemetry_endpoint`, the CLI's OpenTelemetry goes there. `CP_FILES_DIR` is
  the job's folder for the files it leaves to the platform
  (`PipeMaestroRunner.JobFiles`), absolute, and is unset without one.
  """
  @spec env(Job.t(), String.t() | nil, Path.t() | nil) :: [{charlist(), charlist() | false}]
  def env(%Job{} = job, telemetry_endpoint \\ nil, files_dir \\ nil) do
    artifact =
      if job.artifact_path,
        do: [{~c"CP_ARTIFACT_PATH", String.to_charlist(job.artifact_path)}],
        else: [{~c"CP_ARTIFACT_PATH", false}]

    files =
      if files_dir,
        do: [{~c"CP_FILES_DIR", files_dir |> Path.expand() |> String.to_charlist()}],
        else: [{~c"CP_FILES_DIR", false}]

    api_key =
      case System.get_env(@api_key_env) do
        key when key in [nil, ""] -> []
        key -> [{~c"ANTHROPIC_API_KEY", String.to_charlist(key)}]
      end

    secrets =
      for {name, value} <- job.env || %{},
          do: {String.to_charlist(name), String.to_charlist(value)}

    [
      {~c"CLAUDECODE", false},
      {~c"CLAUDE_CODE_ENTRYPOINT", false},
      {~c"__BURRITO", false}
      | artifact ++ files ++ api_key ++ secrets ++ telemetry(job, telemetry_endpoint)
    ]
  end

  # The CLI's OpenTelemetry, to the runner's receiver on this machine
  # (`PipeMaestroRunner.Telemetry.Receiver`), each export naming the
  # job. Short intervals keep it close to the run; contents of prompts,
  # answers and tool arguments stay out.
  defp telemetry(_job, nil), do: []

  defp telemetry(job, endpoint) do
    [
      {~c"CLAUDE_CODE_ENABLE_TELEMETRY", ~c"1"},
      {~c"OTEL_LOGS_EXPORTER", ~c"otlp"},
      {~c"OTEL_METRICS_EXPORTER", ~c"otlp"},
      {~c"OTEL_EXPORTER_OTLP_PROTOCOL", ~c"http/json"},
      {~c"OTEL_EXPORTER_OTLP_ENDPOINT", String.to_charlist(endpoint)},
      {~c"OTEL_LOGS_EXPORT_INTERVAL", ~c"1000"},
      {~c"OTEL_METRIC_EXPORT_INTERVAL", ~c"2000"},
      {~c"OTEL_RESOURCE_ATTRIBUTES", String.to_charlist("cp.job_id=#{job.id}")},
      {~c"OTEL_LOG_USER_PROMPTS", false},
      {~c"OTEL_LOG_ASSISTANT_RESPONSES", false},
      {~c"OTEL_LOG_TOOL_DETAILS", false},
      {~c"OTEL_LOG_TOOL_CONTENT", false}
    ]
  end

  @doc "The runner's own API key for the CLI, if it has one."
  @spec api_key() :: String.t() | nil
  def api_key, do: System.get_env(@api_key_env)

  @doc """
  What the runner announces about the agent (`PipeMaestroProtocol.Hello`
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
