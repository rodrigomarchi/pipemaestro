defmodule ClaudeControlPlaneProtocol.Hello do
  @moduledoc """
  What a runner announces when it joins its channel: who it is and what it can
  run. The control plane stores it and shows it; later the dispatcher matches
  jobs against `labels` and `capacity`.

  `running_job_ids` lists the jobs the runner is still executing. A runner sends
  a new hello on every (re)join, so the control plane can tell a job that lost
  its runner (not listed) from one that survived a dropped connection.
  """

  @enforce_keys [:protocol_version, :runner_version, :hostname, :os, :arch, :labels, :capacity]
  defstruct @enforce_keys ++ [running_job_ids: []]

  @type t :: %__MODULE__{
          protocol_version: pos_integer(),
          runner_version: String.t(),
          hostname: String.t(),
          os: String.t(),
          arch: String.t(),
          labels: [String.t()],
          capacity: pos_integer(),
          running_job_ids: [String.t()]
        }

  @max_labels 32
  @max_running_jobs 64
  @label_format ~r/^[a-z0-9][a-z0-9._-]{0,39}$/

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
         {:ok, running_job_ids} <- running_job_ids(attrs) do
      {:ok,
       %__MODULE__{
         protocol_version: protocol_version,
         runner_version: runner_version,
         hostname: hostname,
         os: os,
         arch: arch,
         labels: labels,
         capacity: capacity,
         running_job_ids: running_job_ids
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
