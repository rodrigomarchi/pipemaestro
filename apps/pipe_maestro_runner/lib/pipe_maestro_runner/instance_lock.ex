defmodule PipeMaestroRunner.InstanceLock do
  @moduledoc """
  One runner at a time per configuration: `runner.pid`, in the runner's
  configuration directory, holds the operating-system pid of the runner
  that runs.

  A runner starting while another one's pid is alive waits for it to end
  (the one that updated itself and is on its way out), up to a limit; a
  file whose pid is gone, or is this one's, does not count. A runner that
  stops connecting, refused for its version, lets go of it (`release/1`)
  before starting the new binary.
  """

  @wait_ms 30_000
  @poll_ms 200

  @doc """
  Takes the lock at `path`, waiting for a live holder to end. Options:
  `:wait_ms` (default 30 s), `:alive?` (`fn os_pid -> boolean`, by default
  `kill -0`) and `:pid` (this runner's, by default `System.pid/0`).
  """
  @spec acquire(Path.t(), keyword()) :: :ok | {:error, {:held, String.t()}}
  def acquire(path, opts \\ []) do
    own = Keyword.get_lazy(opts, :pid, &System.pid/0)
    alive? = Keyword.get(opts, :alive?, &alive?/1)
    deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :wait_ms, @wait_ms)

    with :ok <- wait(path, own, alive?, deadline) do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, own)
    end
  end

  @doc "Lets go of the lock at `path`, when it is this runner's."
  @spec release(Path.t(), String.t()) :: :ok
  def release(path, own \\ System.pid()) do
    if holder(path) == own, do: File.rm(path)
    :ok
  end

  defp wait(path, own, alive?, deadline) do
    case holder(path) do
      holder when holder in [nil, own] ->
        :ok

      holder ->
        cond do
          not alive?.(holder) ->
            :ok

          System.monotonic_time(:millisecond) >= deadline ->
            {:error, {:held, holder}}

          true ->
            Process.sleep(@poll_ms)
            wait(path, own, alive?, deadline)
        end
    end
  end

  defp holder(path) do
    case File.read(path) do
      {:ok, content} -> content |> String.trim() |> blank_to_nil()
      {:error, _reason} -> nil
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(text), do: text

  defp alive?(os_pid) do
    match?({_out, 0}, System.cmd("kill", ["-0", os_pid], stderr_to_stdout: true))
  end
end
