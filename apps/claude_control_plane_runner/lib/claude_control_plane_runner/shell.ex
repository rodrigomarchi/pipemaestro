defmodule ClaudeControlPlaneRunner.Shell do
  @moduledoc """
  Runs a shell command of the platform's (a worktree's setup, a stage's gate)
  in a directory, with stdin closed, keeping the end of its output (stdout
  and stderr together). The command leads its own process group: the caller
  gets its OS pid and can stop it, with everything it started, by signaling
  the group.
  """

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

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    if on_os_pid, do: on_os_pid.(os_pid)
    collect(port, "")
  end

  defp collect(port, output) do
    receive do
      {^port, {:data, data}} -> collect(port, tail(output <> data))
      {^port, {:exit_status, code}} -> {code, valid_utf8(output)}
    end
  end

  defp tail(output) when byte_size(output) <= @output_bytes, do: output

  defp tail(output),
    do: binary_part(output, byte_size(output) - @output_bytes, @output_bytes)

  # The tail may start inside a character: its continuation bytes go.
  defp valid_utf8(<<0b10::2, _bits::6, rest::binary>>), do: valid_utf8(rest)

  defp valid_utf8(data) do
    case :unicode.characters_to_binary(data) do
      binary when is_binary(binary) -> binary
      {_error, valid, _rest} -> valid
    end
  end
end
