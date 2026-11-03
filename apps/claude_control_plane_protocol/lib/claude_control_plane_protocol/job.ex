defmodule ClaudeControlPlaneProtocol.Job do
  @moduledoc """
  A job the control plane hands to a runner, and the names of the messages
  that carry it on the runner's channel (`runner:<id>`).

  A job runs in the runner's own workdir unless it names a `directory` (one of
  those the runner announced, `ClaudeControlPlaneProtocol.Hello`). A job of a
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
  `delivery` asks the runner to deliver a task's stage once it passes: commit
  what changed in the worktree (`"commit_message"`), push the task's branch
  (`"push"`), open or update its draft pull request (`"pr"`: `"title"`,
  `"body"`, `"ready"` to mark it ready) and comment on its issue
  (`"issue_comment"`: `"url"`, `"body"`).
  `parallel` marks a stage of a group that runs at once with its siblings, in
  the same worktree: the runner does not make it wait for them.
  `env` holds the workspace's secrets as environment variables for the
  agent's process (`NAME => value`); the runner never stores them.
  `permissions` says what the agent may do: `"profile"` (one of
  `permission_profiles/0`; without it, `"total"`) and the tool rules to
  `"allow"` and `"deny"` on top, in the CLI's syntax (`"Bash(mix test:*)"`).

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
      `ClaudeControlPlaneProtocol.JobEvent`, `seq` counting from 1.
    * `"job:delta"` — `%{"job_id", "text"}`: what the agent is writing right
      now (`ClaudeControlPlaneProtocol.JobEvent.text_delta/1`), at most a few
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
  """

  alias ClaudeControlPlaneProtocol.Hello

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
                permissions: nil,
                system_prompt: nil,
                mcp_config: nil,
                agents: nil,
                agent: nil,
                env: nil,
                parallel: nil,
                delivery: nil
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
          permissions: %{String.t() => String.t() | [String.t()]} | nil,
          system_prompt: String.t() | nil,
          mcp_config: map() | nil,
          agents: map() | nil,
          agent: String.t() | nil,
          env: %{String.t() => String.t()} | nil,
          parallel: boolean() | nil,
          delivery: map() | nil
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
    :permissions,
    :system_prompt,
    :mcp_config,
    :agents,
    :agent,
    :env,
    :parallel,
    :delivery
  ]

  @env_name ~r/^[A-Z][A-Z0-9_]{0,63}$/
  # What a secret may not override: the process would break or escape.
  @reserved_env ~w(PATH HOME SHELL USER CLAUDECODE CLAUDE_CODE_ENTRYPOINT CP_ARTIFACT_PATH)

  @permission_profiles ~w(total edicao leitura)

  @max_gates 10

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

  @doc "How a job can end, as sent on the wire."
  @spec finished_statuses() :: [String.t()]
  def finished_statuses, do: ~w(succeeded failed canceled)

  @doc """
  What an agent may do: `"total"` (everything, no prompts), `"edicao"` (edit
  files; run only the commands allowed) and `"leitura"` (read and search; write
  only the stage's artifact).
  """
  @spec permission_profiles() :: [String.t()]
  def permission_profiles, do: @permission_profiles

  @doc "The longest prompt a job may carry, in bytes."
  @spec max_prompt_bytes() :: pos_integer()
  def max_prompt_bytes, do: @max_prompt_bytes

  @doc "Builds a validated job from a map with atom or string keys."
  @spec new(map()) :: {:ok, t()} | {:error, String.t()}
  def new(attrs) when is_map(attrs) do
    with {:ok, id} <- id(attrs),
         {:ok, prompt} <- prompt(attrs),
         {:ok, optional} <- optional(attrs) do
      {:ok, struct!(%__MODULE__{id: id, prompt: prompt}, optional)}
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

  defp check(:delivery, %{"commit_message" => message} = delivery)
       when is_binary(message) and byte_size(message) in 1..4_000 do
    if pr?(delivery["pr"]) and issue_comment?(delivery["issue_comment"]) and
         delivery["push"] in [nil, true, false],
       do: :ok,
       else: {:error, "must have a commit message, a titled pr and a comment with url and body"}
  end

  defp check(:delivery, _value), do: {:error, "must have a commit message"}

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

  defp check(:permissions, %{"profile" => profile} = permissions)
       when profile in @permission_profiles do
    rules = [Map.get(permissions, "allow", []), Map.get(permissions, "deny", [])]

    if Enum.all?(rules, &tool_rules?/1),
      do: :ok,
      else: {:error, "allow and deny must be lists of tool rules"}
  end

  defp check(:permissions, _value),
    do: {:error, "must name a profile: #{Enum.join(@permission_profiles, ", ")}"}

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
    do: is_binary(name) and name =~ @env_name and name not in @reserved_env

  defp pr?(nil), do: true
  defp pr?(%{"title" => title} = pr), do: text?(title, 300) and text?(pr["body"] || "x", 60_000)
  defp pr?(_pr), do: false

  defp issue_comment?(nil), do: true

  defp issue_comment?(%{"url" => url, "body" => body}),
    do: text?(url, 500) and text?(body, 60_000)

  defp issue_comment?(_comment), do: false

  defp text?(value, max), do: is_binary(value) and byte_size(value) in 1..max

  defp tool_rules?(rules) when is_list(rules) and length(rules) <= 50,
    do: Enum.all?(rules, &(is_binary(&1) and byte_size(&1) in 1..500))

  defp tool_rules?(_rules), do: false

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
