defmodule ClaudeControlPlaneProtocol.Job do
  @moduledoc """
  A job the control plane hands to a runner, and the names of the messages
  that carry it on the runner's channel (`runner:<id>`).

  Control plane → runner:

    * `"job:assign"` — the job (`to_map/1`); the runner queues it.
    * `"job:cancel"` — `%{"job_id" => id}`; the runner drops it or stops it.

  Runner → control plane:

    * `"job:started"` — `%{"job_id" => id}`.
    * `"job:event"` — `%{"job_id", "seq", "type", "data"}`, one per
      `ClaudeControlPlaneProtocol.JobEvent`, `seq` counting from 1.
    * `"job:finished"` — `%{"job_id", "status", "exit_code", "result",
      "cost_usd", "duration_ms", "num_turns"}` with `status` one of
      `finished_statuses/0`.
  """

  @enforce_keys [:id, :prompt]
  defstruct @enforce_keys

  @type t :: %__MODULE__{id: String.t(), prompt: String.t()}

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

  @doc "The runner reports how a job ended."
  @spec finished_event() :: String.t()
  def finished_event, do: "job:finished"

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
         {:ok, prompt} <- prompt(attrs) do
      {:ok, %__MODULE__{id: id, prompt: prompt}}
    end
  end

  def new(_attrs), do: {:error, "job must be a map"}

  @doc "The wire form: a map with string keys."
  @spec to_map(t()) :: %{String.t() => String.t()}
  def to_map(%__MODULE__{id: id, prompt: prompt}), do: %{"id" => id, "prompt" => prompt}

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
end
