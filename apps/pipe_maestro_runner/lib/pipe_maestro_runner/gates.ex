defmodule PipeMaestroRunner.Gates do
  @moduledoc """
  A stage's gates (`PipeMaestroProtocol.Job` `gates`): shell commands
  run in the working directory after the agent ends well, one after another,
  each expected to pass (exit 0) or to fail. The runner only reports; the
  control plane decides what a gate not met means for the task.
  """

  alias PipeMaestroRunner.Shell

  @doc """
  Runs every gate in `dir`; each result is the gate plus `"exit_code"`,
  `"output"` (its end), `"passed"` (whether it met its expectation) and
  `"duration_ms"`. `on_os_pid` gets each command's OS pid, to stop it.
  """
  @spec run(Path.t(), [map()], (non_neg_integer() -> any()) | nil) :: [map()]
  def run(dir, gates, on_os_pid \\ nil) do
    Enum.map(gates, fn %{"command" => command, "expect" => expect} = gate ->
      started = System.monotonic_time(:millisecond)
      {exit_code, output} = Shell.run(dir, command, on_os_pid)

      Map.merge(gate, %{
        "exit_code" => exit_code,
        "output" => output,
        "passed" => if(expect == "pass", do: exit_code == 0, else: exit_code != 0),
        "duration_ms" => System.monotonic_time(:millisecond) - started
      })
    end)
  end
end
