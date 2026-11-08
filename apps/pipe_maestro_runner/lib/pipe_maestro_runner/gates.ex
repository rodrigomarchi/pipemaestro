defmodule PipeMaestroRunner.Gates do
  @moduledoc """
  A stage's gates (`PipeMaestroProtocol.Job` `gates`): shell commands
  run in the working directory after the agent ends well, one after another,
  each expected to pass (exit 0) or to fail. The runner only reports; the
  control plane decides what a gate not met means for the task.

  A gate that already passed on the same tree (`PipeMaestroRunner.GateCache`)
  is not run again: its result says so, with `"cached" => true`.
  """

  alias PipeMaestroRunner.{GateCache, Shell}

  @doc """
  Runs every gate in `dir`; each result is the gate plus `"exit_code"`,
  `"output"` (its end), `"passed"` (whether it met its expectation) and
  `"duration_ms"`, and `"cached" => true` when it was not run because it had
  passed on this tree.

  Options: `:on_os_pid`, called with each command's OS pid, to stop it;
  `:exclude`, paths relative to `dir` left out of the tree the cache is keyed
  on (the task's artifacts, what the setup copied).
  """
  @spec run(Path.t(), [map()], keyword()) :: [map()]
  def run(dir, gates, opts \\ []) do
    on_os_pid = Keyword.get(opts, :on_os_pid)
    cache = GateCache.open(dir, Keyword.get(opts, :exclude, []))

    results =
      Enum.map(gates, fn gate ->
        case GateCache.lookup(cache, gate) do
          nil -> run_one(dir, gate, on_os_pid)
          hit -> cached(cache, gate, hit)
        end
      end)

    :ok = GateCache.remember(cache, Enum.reject(results, & &1["cached"]))
    results
  end

  defp run_one(dir, %{"command" => command, "expect" => expect} = gate, on_os_pid) do
    started = System.monotonic_time(:millisecond)
    {exit_code, output} = Shell.run(dir, command, on_os_pid)

    Map.merge(gate, %{
      "exit_code" => exit_code,
      "output" => output,
      "passed" => if(expect == "pass", do: exit_code == 0, else: exit_code != 0),
      "duration_ms" => System.monotonic_time(:millisecond) - started
    })
  end

  defp cached(cache, gate, %{"at" => at, "exit_code" => exit_code}) do
    Map.merge(gate, %{
      "exit_code" => exit_code,
      "output" =>
        "Não rodou de novo: este gate já passou nesta mesma árvore " <>
          "(#{GateCache.short_tree(cache)}) em #{at}.",
      "passed" => true,
      "duration_ms" => 0,
      "cached" => true
    })
  end
end
