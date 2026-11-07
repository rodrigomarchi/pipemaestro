defmodule PipeMaestroProtocol.Job do
  @moduledoc """
  A job the control plane hands to a runner, and the names of the messages
  that carry it on the runner's channel (`runner:<id>`).

  A job runs in the runner's own workdir unless it names a `directory` (one of
  those the runner announced, `PipeMaestroProtocol.Hello`). A job of a
  task also carries a `worktree`: the runner works in a git worktree of that
  directory, one per task, on the given branch, shared by the task's stages.
  `output_schema`, `model` and `max_budget_usd` go to the agent CLI as they
  are; `artifact_path` is where the agent writes its artifact, relative to
  the working directory, and the runner sends it back when the job ends.
  `timeout_ms` is how long the agent may run before the runner stops it.
  `gates` are shell commands the runner runs in the working directory after
  the agent ends well, each expected to `"pass"` (exit 0) or `"fail"`.
  `system_prompt` is appended to the agent's system prompt, `mcp_config`
  (`%{"mcpServers" => ...}`) adds MCP servers, `agents` defines subagents
  (the CLI's `--agents` object) and `agent` names the agent that runs the job.
  `delivery` asks the runner to deliver a task's stage once it passes: push
  the task's branch as the agent left it (`"push"`; the runner never commits),
  open or adopt its pull request and write its own part of it (`"pr"`:
  `"title"`, used only when the runner opens it, `"block"`, the text kept
  between the platform's markers in the description, and `"ready"`, which
  takes the draft prefix off the title), comment on its issue
  (`"issue_comment"`: `"url"`, `"body"`) and set a commit status on what it
  pushed (`"status"`: `"context"`, `"state"`, `"description"`,
  `"target_url"`).
  `git_credential` signs git in to the repository's host
  (`"host"`, `"username"`, `"password"`, `"expires_at"`), renewed by
  `"job:credential"`; only a runner with the capability `"git_credential"`
  gets it (ADR 0037).
  `checks` are the platform's own verifications of a task's worktree, run
  with the gates (`%{"id" => id}` plus its parameters): `"branch"`
  (`"branch"`: HEAD is on it), `"no_operation"` (no merge, rebase or
  cherry-pick under way), `"contains_origin"` (`"branch"`: the branch holds
  what origin has of it), `"clean"` (nothing left uncommitted but the paths the
  setup copied, nor the task's artifacts folder `"artifacts"`),
  `"artifact_committed"` (`"path"`: the stage's artifact committed as it is
  on disk), `"no_artifacts"` (`"path"`: the artifacts folder not in HEAD) and
  `"no_secrets"` (no value of `env` in what the branch changed). Each result is reported with
  the gates, with `"platform" => true` and a `"message"` written for the agent.
  `sync` asks the runner, before the agent, to fetch the task's branch,
  fast-forward the worktree when that is safe, and tell the agent, in its
  prompt, what it finds otherwise (a divergence, an operation under way).
  `artifacts` are the earlier stages' artifacts (`%{"path", "content"}`): the
  runner writes the ones missing on disk before the agent starts.
  `parallel` marks a stage of a group that runs at once with its siblings, in
  the same worktree: the runner does not make it wait for them.
  `env` holds the workspace's secrets as environment variables for the
  agent's process (`NAME => value`); the runner never stores them.
  The agent always runs with every permission: a job carries no permission
  settings, and a `"permissions"` key from an older control plane is ignored.

  `scratch` runs the job in a disposable git worktree of `directory`,
  detached at its `HEAD` and removed when the job ends: the agent may read,
  build and test, but nothing it does reaches the directory. It needs a
  `directory` and takes no `worktree` nor `delivery`. A runner older than
  this field would run the job in the directory itself, so the control plane
  sends it only to runners that announce the `"scratch"` capability
  (`PipeMaestroProtocol.Hello`).

  `persist_session` keeps the agent CLI's session of this job on the runner's
  machine, so a later stage can continue it; without it the CLI keeps none.
  `resume_session_id` names the session of an earlier job (the `session_id` it
  reported) the agent continues, forked into a session of its own, with this
  job's prompt as the next message. When the CLI does not have that session,
  the runner runs the job once more from scratch and reports
  `"session_resumed" => false` in `"job:finished"` (`true` when it resumed).
  A job of a scratch run resumes nothing. Only a runner with the capability
  `"resume_session"` gets these fields; an older one ignores them and runs the
  job from scratch.

  `setup` prepares a task's worktree once, when the runner creates it:
  `"copy"` names paths of the directory (dependencies, build output) the runner
  clones into the worktree, copy-on-write where the file system allows, and
  `"command"` is a shell command run in the worktree afterwards. Without
  `"copy"` the runner picks the usual ones for the toolchains it finds.

  Control plane → runner:

    * `"job:assign"` — the job (`to_map/1`); the runner queues it.
    * `"job:cancel"` — `%{"job_id" => id}`; the runner drops it or stops it.

  Runner → control plane:

    * `"job:started"` — `%{"job_id" => id}`.
    * `"job:event"` — `%{"job_id", "seq", "type", "data"}`, one per
      `PipeMaestroProtocol.JobEvent`, `seq` counting from 1.
    * `"job:delta"` — `%{"job_id", "text"}`: what the agent is writing right
      now (`PipeMaestroProtocol.JobEvent.text_delta/1`), at most a few
      times a second. Not stored and not sent again: the full message comes as
      a `job:event`.
    * `"job:finished"` — `%{"job_id", "status", "exit_code", "result",
      "cost_usd", "duration_ms", "num_turns", "structured_output", "artifact",
      "workdir", "setup", "changes", "gates", "delivery", "error"}` with
      `status` one of
      `finished_statuses/0`; all but `job_id` and `status` may be missing.
      `setup` reports a worktree prepared by this job: `%{"duration_ms",
      "copied", "command", "exit_code", "output"}`. `changes` reports, for a
      job in a task's worktree, what it changed there: `%{"files", "patch",
      "truncated", "task_files"}`, each file `%{"path", "added", "removed"}`.
      `gates` reports each gate command run: `%{"command", "expect",
      "exit_code", "output", "passed", "duration_ms"}`. `delivery` reports
      what the runner delivered: `%{"commit", "pushed", "pr_url",
      "commented", "error"}`.

      For auditing, it also carries what the run reported about itself:
      `session_id`, `cli_version`, `model`, `stop_reason`, `result_subtype`,
      `duration_api_ms`, `ttft_ms`, `wall_ms` (the agent's process, timed by
      the runner), `usage` (`%{"fresh_input", "cache_read", "cache_creation",
      "output", "thinking"}`), `model_usage` (per model: those tokens and
      `cost_usd`), `permission_denials`, `environment` (what the agent had at
      hand: `tools`, `mcp_servers`, `agents`, `skills`, `slash_commands`,
      `plugins`, `permission_mode`, `auth`, `output_style`), `subagents` and
      `stderr` (the last of what the CLI wrote there), and `session_resumed`
      when the job asked to resume a session.
    * `"job:telemetry"` — what the CLI's OpenTelemetry reported
      (`PipeMaestroProtocol.Telemetry`); may arrive after
      `"job:finished"`.
  """

  alias PipeMaestroProtocol.Hello

  @enforce_keys [:id, :prompt]
  defstruct @enforce_keys ++
              [
                directory: nil,
                worktree: nil,
                output_schema: nil,
                model: nil,
                max_budget_usd: nil,
                artifact_path: nil,
                setup: nil,
                timeout_ms: nil,
                gates: nil,
                system_prompt: nil,
                mcp_config: nil,
                agents: nil,
                agent: nil,
                env: nil,
                parallel: nil,
                delivery: nil,
                scratch: nil,
                checks: nil,
                sync: nil,
                artifacts: nil,
                git_credential: nil,
                persist_session: nil,
                resume_session_id: nil
              ]

  @type worktree :: %{String.t() => String.t()}
  @type setup :: %{optional(String.t()) => String.t() | [String.t()]}

  @type t :: %__MODULE__{
          id: String.t(),
          prompt: String.t(),
          directory: String.t() | nil,
          worktree: worktree() | nil,
          output_schema: map() | nil,
          model: String.t() | nil,
          max_budget_usd: number() | nil,
          artifact_path: String.t() | nil,
          setup: setup() | nil,
          timeout_ms: pos_integer() | nil,
          gates: [%{String.t() => String.t()}] | nil,
          system_prompt: String.t() | nil,
          mcp_config: map() | nil,
          agents: map() | nil,
          agent: String.t() | nil,
          env: %{String.t() => String.t()} | nil,
          parallel: boolean() | nil,
          delivery: map() | nil,
          scratch: boolean() | nil,
          checks: [map()] | nil,
          sync: boolean() | nil,
          artifacts: [%{String.t() => String.t()}] | nil,
          git_credential: %{String.t() => String.t()} | nil,
          persist_session: boolean() | nil,
          resume_session_id: String.t() | nil
        }

  @optional [
    :directory,
    :worktree,
    :output_schema,
    :model,
    :max_budget_usd,
    :artifact_path,
    :setup,
    :timeout_ms,
    :gates,
    :system_prompt,
    :mcp_config,
    :agents,
    :agent,
    :env,
    :parallel,
    :delivery,
    :scratch,
    :checks,
    :sync,
    :artifacts,
    :git_credential,
    :persist_session,
    :resume_session_id
  ]

  @check_ids ~w(branch no_operation contains_origin clean artifact_committed no_artifacts no_secrets)
  @max_artifacts 40
  @max_artifact_bytes 65_536

  @env_name ~r/^[A-Z][A-Z0-9_]{0,63}$/
  # What a secret may not override: the process would break or escape.
  @reserved_env ~w(PATH HOME SHELL USER CLAUDECODE CLAUDE_CODE_ENTRYPOINT CP_ARTIFACT_PATH
                   PIPEMAESTRO_GIT_CREDENTIAL_FILE)

  @max_gates 10

  @session_id ~r/^[A-Za-z0-9][A-Za-z0-9_-]{0,99}$/

  @max_timeout_ms 24 * 60 * 60 * 1000

  @max_prompt_bytes 32_000

  @doc "The control plane gives the runner a job."
  @spec assign_event() :: String.t()
  def assign_event, do: "job:assign"

  @doc "The control plane asks the runner to drop or stop a job."
  @spec cancel_event() :: String.t()
  def cancel_event, do: "job:cancel"

  @doc "The runner started a job."
  @spec started_event() :: String.t()
  def started_event, do: "job:started"

  @doc "The runner reports one event of a running job."
  @spec event_event() :: String.t()
  def event_event, do: "job:event"

  @doc "The runner relays what the agent is writing (not stored)."
  @spec delta_event() :: String.t()
  def delta_event, do: "job:delta"

  @doc "The runner reports how a job ended."
  @spec finished_event() :: String.t()
  def finished_event, do: "job:finished"

  @doc """
  The control plane renews a running job's `git_credential`
  (`%{"job_id", "git_credential"}`), before it expires.
  """
  @spec credential_event() :: String.t()
  def credential_event, do: "job:credential"

  @doc "How a job can end, as sent on the wire."
  @spec finished_statuses() :: [String.t()]
  def finished_statuses, do: ~w(succeeded failed canceled)

  @doc "The longest prompt a job may carry, in bytes."
  @spec max_prompt_bytes() :: pos_integer()
  def max_prompt_bytes, do: @max_prompt_bytes

  @doc "Builds a validated job from a map with atom or string keys."
  @spec new(map()) :: {:ok, t()} | {:error, String.t()}
  def new(attrs) when is_map(attrs) do
    with {:ok, id} <- id(attrs),
         {:ok, prompt} <- prompt(attrs),
         {:ok, optional} <- optional(attrs) do
      %__MODULE__{id: id, prompt: prompt} |> struct!(optional) |> consistent()
    end
  end

  def new(_attrs), do: {:error, "job must be a map"}

  @doc "The wire form: a map with string keys."
  @spec to_map(t()) :: %{String.t() => term()}
  def to_map(%__MODULE__{} = job) do
    for {key, value} <- Map.from_struct(job),
        value != nil,
        into: %{},
        do: {Atom.to_string(key), value}
  end

  @doc "Parses the wire form."
  @spec from_map(map()) :: {:ok, t()} | {:error, String.t()}
  def from_map(map), do: new(map)

  defp fetch(attrs, key), do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))

  defp id(attrs) do
    case fetch(attrs, :id) do
      id when is_binary(id) and byte_size(id) in 1..64 -> {:ok, id}
      _other -> {:error, "id must be a job id"}
    end
  end

  defp prompt(attrs) do
    case fetch(attrs, :prompt) do
      prompt when is_binary(prompt) and byte_size(prompt) in 1..@max_prompt_bytes ->
        {:ok, prompt}

      _other ->
        {:error, "prompt must be a string of 1 to #{@max_prompt_bytes} bytes"}
    end
  end

  defp optional(attrs) do
    Enum.reduce_while(@optional, {:ok, []}, fn key, {:ok, acc} ->
      case optional_value(key, fetch(attrs, key)) do
        :absent -> {:cont, {:ok, acc}}
        {:ok, value} -> {:cont, {:ok, [{key, value} | acc]}}
        {:error, message} -> {:halt, {:error, "#{key} #{message}"}}
      end
    end)
  end

  defp optional_value(_key, nil), do: :absent

  defp optional_value(key, value) do
    with :ok <- check(key, value), do: {:ok, value}
  end

  defp consistent(%__MODULE__{scratch: true, directory: nil}),
    do: {:error, "scratch needs a directory"}

  defp consistent(%__MODULE__{scratch: true, worktree: worktree, delivery: delivery})
       when worktree != nil or delivery != nil,
       do: {:error, "scratch takes no worktree nor delivery"}

  defp consistent(%__MODULE__{scratch: true, resume_session_id: id}) when id != nil,
    do: {:error, "scratch resumes no session"}

  defp consistent(%__MODULE__{} = job), do: {:ok, job}

  defp check(:scratch, value) when is_boolean(value), do: :ok
  defp check(:scratch, _value), do: {:error, "must be a boolean"}

  defp check(:persist_session, value) when is_boolean(value), do: :ok
  defp check(:persist_session, _value), do: {:error, "must be true or false"}

  defp check(:resume_session_id, value) when is_binary(value) do
    if value =~ @session_id, do: :ok, else: {:error, "must be a session id"}
  end

  defp check(:resume_session_id, _value), do: {:error, "must be a session id"}

  defp check(:directory, value) do
    if Hello.valid_directory_name?(value), do: :ok, else: {:error, "must be a directory name"}
  end

  defp check(:worktree, %{"task_id" => task_id, "branch" => branch})
       when is_binary(task_id) and byte_size(task_id) in 1..64 and is_binary(branch) and
              byte_size(branch) in 1..200,
       do: :ok

  defp check(:worktree, _value), do: {:error, "must have a task_id and a branch"}
  defp check(:output_schema, value) when is_map(value), do: :ok
  defp check(:output_schema, _value), do: {:error, "must be a JSON Schema object"}
  defp check(:model, value) when is_binary(value) and byte_size(value) in 1..80, do: :ok
  defp check(:model, _value), do: {:error, "must be a model name"}
  defp check(:max_budget_usd, value) when is_number(value) and value > 0, do: :ok
  defp check(:max_budget_usd, _value), do: {:error, "must be a positive number"}

  defp check(:artifact_path, value) do
    if inner_path?(value),
      do: :ok,
      else: {:error, "must be a relative path inside the working directory"}
  end

  defp check(:system_prompt, value) when is_binary(value) and byte_size(value) in 1..16_000,
    do: :ok

  defp check(:system_prompt, _value), do: {:error, "must be a text of up to 16 000 bytes"}

  defp check(:mcp_config, %{"mcpServers" => servers}) when is_map(servers), do: :ok
  defp check(:mcp_config, _value), do: {:error, "must be an object with mcpServers"}

  defp check(:agents, value) when is_map(value) and map_size(value) <= 20, do: :ok
  defp check(:agents, _value), do: {:error, "must be an object of agents by name"}

  defp check(:delivery, %{} = delivery) do
    if pr?(delivery["pr"]) and issue_comment?(delivery["issue_comment"]) and
         status?(delivery["status"]) and delivery["push"] in [nil, true, false],
       do: :ok,
       else: {:error, "must have a titled pr, a comment with url and body and a valid status"}
  end

  defp check(
         :git_credential,
         %{"host" => host, "username" => user, "password" => password} = credential
       ) do
    if text?(host, 255) and text?(user, 255) and text?(password, 4_096) and
         (credential["expires_at"] == nil or text?(credential["expires_at"], 40)),
       do: :ok,
       else: {:error, "must have a host, a username and a password"}
  end

  defp check(:git_credential, _value), do: {:error, "must have a host, a username and a password"}

  defp check(:delivery, _value), do: {:error, "must be an object"}

  defp check(:checks, checks) when is_list(checks) and length(checks) <= 10 do
    if Enum.all?(checks, &platform_check?/1),
      do: :ok,
      else: {:error, "must be known checks (#{Enum.join(@check_ids, ", ")})"}
  end

  defp check(:checks, _value), do: {:error, "must be a list of checks"}

  defp check(:sync, value) when is_boolean(value), do: :ok
  defp check(:sync, _value), do: {:error, "must be true or false"}

  defp check(:artifacts, artifacts)
       when is_list(artifacts) and length(artifacts) <= @max_artifacts do
    if Enum.all?(artifacts, &artifact?/1),
      do: :ok,
      else: {:error, "must be paths inside the directory, each with its content"}
  end

  defp check(:artifacts, _value), do: {:error, "must be a list of up to #{@max_artifacts}"}

  defp check(:env, env) when is_map(env) and map_size(env) <= 50 do
    if Enum.all?(env, fn {name, value} ->
         env_name?(name) and is_binary(value) and byte_size(value) <= 8_192
       end),
       do: :ok,
       else: {:error, "must map variable names (A-Z, 0-9, _) to texts"}
  end

  defp check(:env, _value), do: {:error, "must be a map of up to 50 variables"}

  defp check(:parallel, value) when is_boolean(value), do: :ok
  defp check(:parallel, _value), do: {:error, "must be true or false"}

  defp check(:agent, value) when is_binary(value) and byte_size(value) in 1..100, do: :ok
  defp check(:agent, _value), do: {:error, "must be an agent name"}

  defp check(:timeout_ms, value) when is_integer(value) and value in 1..@max_timeout_ms, do: :ok
  defp check(:timeout_ms, _value), do: {:error, "must be a number of milliseconds up to a day"}

  defp check(:gates, gates) when is_list(gates) and length(gates) <= @max_gates do
    if Enum.all?(gates, &gate?/1),
      do: :ok,
      else: {:error, "must be commands, each expected to pass or fail"}
  end

  defp check(:gates, _value), do: {:error, "must be a list of up to #{@max_gates} commands"}

  defp check(:setup, %{} = setup) when map_size(setup) > 0 do
    if Enum.all?(setup, &setup_entry?/1),
      do: :ok,
      else: {:error, "must have a command and paths inside the directory to copy"}
  end

  defp check(:setup, _value), do: {:error, "must be a map with a command or paths to copy"}

  @doc "Whether `name` can be a secret's variable: A-Z, 0-9 and _, not one the runner needs."
  @spec env_name?(term()) :: boolean()
  def env_name?(name),
    do:
      is_binary(name) and name =~ @env_name and name not in @reserved_env and
        not String.starts_with?(name, "GIT_CONFIG")

  defp status?(nil), do: true

  defp status?(%{"context" => context, "state" => state} = status),
    do:
      text?(context, 255) and state in ~w(pending success error failure warning) and
        text?(status["description"] || "x", 255) and text?(status["target_url"] || "x", 2_000)

  defp status?(_status), do: false

  defp pr?(nil), do: true

  defp pr?(%{"title" => title} = pr),
    do:
      text?(title, 300) and text?(pr["block"] || "x", 60_000) and
        pr["ready"] in [nil, true, false]

  defp pr?(_pr), do: false

  defp platform_check?(%{"id" => id} = check) when id in @check_ids,
    do: Enum.all?(Map.delete(check, "id"), fn {_key, value} -> text?(value, 255) end)

  defp platform_check?(_check), do: false

  defp artifact?(%{"path" => path, "content" => content}),
    do: inner_path?(path) and is_binary(content) and byte_size(content) <= @max_artifact_bytes

  defp artifact?(_artifact), do: false

  defp issue_comment?(nil), do: true

  defp issue_comment?(%{"url" => url, "body" => body}),
    do: text?(url, 500) and text?(body, 60_000)

  defp issue_comment?(_comment), do: false

  defp text?(value, max), do: is_binary(value) and byte_size(value) in 1..max

  defp gate?(%{"command" => command, "expect" => expect}),
    do: is_binary(command) and byte_size(command) in 1..4_000 and expect in ["pass", "fail"]

  defp gate?(_gate), do: false

  defp setup_entry?({"command", command}),
    do: is_binary(command) and byte_size(command) in 1..4_000

  defp setup_entry?({"copy", paths}),
    do: is_list(paths) and length(paths) <= 50 and Enum.all?(paths, &inner_path?/1)

  defp setup_entry?(_other), do: false

  defp inner_path?(value) when is_binary(value) and byte_size(value) in 1..255,
    do: Path.type(value) == :relative and ".." not in Path.split(value)

  defp inner_path?(_value), do: false
end
