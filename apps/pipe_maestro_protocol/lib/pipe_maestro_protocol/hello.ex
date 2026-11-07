defmodule PipeMaestroProtocol.Hello do
  @moduledoc """
  What a runner announces when it joins its channel: who it is and what it can
  run. The control plane stores it and shows it; later the dispatcher matches
  jobs against `labels` and `capacity`.

  `running_job_ids` lists the jobs the runner is still executing. A runner sends
  a new hello on every (re)join, so the control plane can tell a job that lost
  its runner (not listed) from one that survived a dropped connection.

  `directories` lists the code directories the runner offers, the first level
  of the root it was started with (`%{"name" => "my_app", "git" => true}`). A
  task picks one of them to work in.

  `agent` describes the agent CLI on the machine: `"cli_version"` (`nil` when
  it was not found) and `"auth"`, how it authenticates: `"api_key"` (the
  runner's own key) or `"login"` (whoever is signed in to the CLI).

  `capabilities` names what this runner supports beyond the protocol version,
  so the control plane offers a feature only to runners that have it:
  `"scratch"` runs a job in a disposable worktree (`PipeMaestroProtocol.Job`).
  A runner that sends none has none.
  """

  @enforce_keys [:protocol_version, :runner_version, :hostname, :os, :arch, :labels, :capacity]
  defstruct @enforce_keys ++ [running_job_ids: [], directories: [], agent: nil, capabilities: []]

  @type t :: %__MODULE__{
          protocol_version: pos_integer(),
          runner_version: String.t(),
          hostname: String.t(),
          os: String.t(),
          arch: String.t(),
          labels: [String.t()],
          capacity: pos_integer(),
          running_job_ids: [String.t()],
          directories: [directory()],
          agent: %{String.t() => String.t() | nil} | nil,
          capabilities: [String.t()]
        }

  @typedoc "A code directory the runner offers, in the wire form."
  @type directory :: %{String.t() => String.t() | boolean()}

  @max_labels 32
  @max_running_jobs 64
  @max_directories 500
  @label_format ~r/^[a-z0-9][a-z0-9._-]{0,39}$/
  @max_capabilities 32

  @doc "What a runner of this build supports (`capabilities`)."
  @spec capabilities() :: [String.t()]
  def capabilities, do: ["doctor", "git_credential", "health", "logs", "scratch"]

  @doc """
  Builds a validated hello from a map with atom or string keys. Labels are
  lowercased, deduplicated and sorted.
  """
  @spec new(map()) :: {:ok, t()} | {:error, String.t()}
  def new(attrs) when is_map(attrs) do
    with {:ok, protocol_version} <- positive_integer(attrs, :protocol_version),
         {:ok, runner_version} <- text(attrs, :runner_version),
         {:ok, hostname} <- text(attrs, :hostname),
         {:ok, os} <- text(attrs, :os),
         {:ok, arch} <- text(attrs, :arch),
         {:ok, labels} <- labels(attrs),
         {:ok, capacity} <- positive_integer(attrs, :capacity),
         {:ok, running_job_ids} <- running_job_ids(attrs),
         {:ok, directories} <- parse_directories(fetch(attrs, :directories) || []),
         {:ok, agent} <- agent(fetch(attrs, :agent)),
         {:ok, capabilities} <- capabilities(fetch(attrs, :capabilities)) do
      {:ok,
       %__MODULE__{
         protocol_version: protocol_version,
         runner_version: runner_version,
         hostname: hostname,
         os: os,
         arch: arch,
         labels: labels,
         capacity: capacity,
         running_job_ids: running_job_ids,
         directories: directories,
         agent: agent,
         capabilities: capabilities
       }}
    end
  end

  def new(_attrs), do: {:error, "hello must be a map"}

  @doc "The wire form: a map with string keys."
  @spec to_map(t()) :: %{String.t() => term()}
  def to_map(%__MODULE__{} = hello) do
    hello |> Map.from_struct() |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
  end

  @doc "Parses the wire form."
  @spec from_map(map()) :: {:ok, t()} | {:error, String.t()}
  def from_map(map), do: new(map)

  defp capabilities(nil), do: {:ok, []}

  defp capabilities(list) when is_list(list) and length(list) <= @max_capabilities do
    if Enum.all?(list, &(is_binary(&1) and Regex.match?(@label_format, &1))),
      do: {:ok, list |> Enum.uniq() |> Enum.sort()},
      else: {:error, "capabilities must be lowercase words"}
  end

  defp capabilities(_list),
    do: {:error, "capabilities must be a list of at most #{@max_capabilities} names"}

  defp agent(nil), do: {:ok, nil}

  defp agent(%{} = agent) do
    version = Map.get(agent, "cli_version")
    auth = Map.get(agent, "auth")

    if auth in ["api_key", "login"] and
         (is_nil(version) or (is_binary(version) and byte_size(version) <= 40)),
       do: {:ok, %{"cli_version" => version, "auth" => auth}},
       else: {:error, "agent must say how the CLI authenticates (api_key or login)"}
  end

  defp agent(_agent), do: {:error, "agent must be a map"}

  defp fetch(attrs, key), do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))

  defp positive_integer(attrs, key) do
    case fetch(attrs, key) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _other -> {:error, "#{key} must be a positive integer"}
    end
  end

  defp text(attrs, key) do
    case fetch(attrs, key) do
      value when is_binary(value) and byte_size(value) in 1..120 -> {:ok, value}
      _other -> {:error, "#{key} must be a string of 1 to 120 bytes"}
    end
  end

  defp labels(attrs) do
    case fetch(attrs, :labels) do
      list when is_list(list) and length(list) <= @max_labels ->
        normalized = list |> Enum.map(&normalize_label/1) |> Enum.uniq() |> Enum.sort()

        if Enum.all?(normalized, &(is_binary(&1) and Regex.match?(@label_format, &1))),
          do: {:ok, normalized},
          else: {:error, "labels must be lowercase words of letters, digits, '.', '_' or '-'"}

      _other ->
        {:error, "labels must be a list of at most #{@max_labels} strings"}
    end
  end

  @doc """
  Parses a list of directories from the wire: each a map with a `name` (one
  path segment, never `.` or `..`) and a `git` flag. Sorted by name.
  """
  @spec parse_directories(term()) :: {:ok, [directory()]} | {:error, String.t()}
  def parse_directories(list) when is_list(list) and length(list) <= @max_directories do
    parsed = Enum.map(list, &parse_directory/1)

    if Enum.all?(parsed, &is_map/1),
      do: {:ok, parsed |> Enum.uniq_by(& &1["name"]) |> Enum.sort_by(& &1["name"])},
      else: {:error, "directories must be maps with a name (one path segment) and a git flag"}
  end

  def parse_directories(_list),
    do: {:error, "directories must be a list of at most #{@max_directories} entries"}

  defp parse_directory(%{} = dir) do
    name = Map.get(dir, "name", Map.get(dir, :name))
    git = Map.get(dir, "git", Map.get(dir, :git, false))

    if valid_directory_name?(name) and is_boolean(git),
      do: %{"name" => name, "git" => git},
      else: :invalid
  end

  defp parse_directory(_dir), do: :invalid

  @doc "Whether `name` is a single directory name: no separator, not `.` or `..`."
  @spec valid_directory_name?(term()) :: boolean()
  def valid_directory_name?(name) when is_binary(name) and byte_size(name) in 1..255,
    do: name not in [".", ".."] and not String.contains?(name, ["/", "\\", <<0>>])

  def valid_directory_name?(_name), do: false

  defp running_job_ids(attrs) do
    case fetch(attrs, :running_job_ids) do
      nil ->
        {:ok, []}

      list when is_list(list) and length(list) <= @max_running_jobs ->
        if Enum.all?(list, &(is_binary(&1) and byte_size(&1) in 1..64)),
          do: {:ok, list},
          else: {:error, "running_job_ids must be job ids"}

      _other ->
        {:error, "running_job_ids must be a list of at most #{@max_running_jobs} job ids"}
    end
  end

  defp normalize_label(label) when is_binary(label),
    do: label |> String.trim() |> String.downcase()

  defp normalize_label(other), do: other
end
