defmodule PipeMaestroRunner.Shell do
  @moduledoc """
  Runs a shell command of the platform's (a worktree's setup, a stage's gate)
  in a directory, with stdin closed, keeping the end of its output (stdout
  and stderr together). The command leads its own process group: the caller
  gets its OS pid and can stop it, with everything it started, by signaling
  the group.
  """

  alias PipeMaestroProtocol.Text

  @output_bytes 8_192

  @doc """
  Runs `command` with `/bin/sh` in `dir`; returns its exit status and the last
  8 KB of its output. `on_os_pid`, if given, is called with the command's OS
  pid as soon as it starts.
  """
  @spec run(Path.t(), String.t(), (non_neg_integer() -> any()) | nil) ::
          {non_neg_integer(), String.t()}
  def run(dir, command, on_os_pid \\ nil) do
    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:cd, dir},
        {:args, ["-c", command <> " < /dev/null"]}
      ])

    # A quick command may already be gone: nothing left to stop then.
    with {:os_pid, os_pid} <- Port.info(port, :os_pid),
         true <- on_os_pid != nil,
         do: on_os_pid.(os_pid)

    collect(port, "")
  end

  @doc """
  Sends `signal` to the process group led by `os_pid`, which takes everything
  the command started. Right after the command is spawned the group may not
  exist yet; then the signal goes to the process itself.
  """
  @spec signal(non_neg_integer(), String.t()) :: :ok
  def signal(os_pid, signal) do
    case System.cmd("kill", ["-s", signal, "--", "-#{os_pid}"], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      _no_group -> _sent = System.cmd("kill", ["-s", signal, "#{os_pid}"], stderr_to_stdout: true)
    end

    :ok
  end

  defp collect(port, output) do
    receive do
      {^port, {:data, data}} -> collect(port, tail(output <> data))
      {^port, {:exit_status, code}} -> {code, Text.valid_utf8(output)}
    end
  end

  defp tail(output) when byte_size(output) <= @output_bytes, do: output

  defp tail(output),
    do: binary_part(output, byte_size(output) - @output_bytes, @output_bytes)
end
