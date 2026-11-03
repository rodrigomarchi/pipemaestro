defmodule ClaudeControlPlaneRunner.Commands.Service do
  @moduledoc """
  Runs the runner in the background as a service of the current user
  (`ClaudeControlPlaneRunner.Service`): a launchd agent on macOS, a systemd
  user unit on Linux. It uses the saved credentials and root, so sign in and
  start once by hand first (`cp-runner login`, `cp-runner start --root`).

      cp-runner service print       # shows the service file
      cp-runner service install     # writes it and starts the service
      cp-runner service uninstall   # stops the service and removes the file

  The output goes to `runner.log` next to the credentials.
  """

  alias ClaudeControlPlaneRunner.{Config, Output, Service}
  @spec run([String.t()]) :: any()
  def run([action]) when action in ["print", "install", "uninstall"] do
    _config = Output.config!()
    os = :os.type()
    definition = Service.definition(os, options())

    case action do
      "print" ->
        Output.info("# #{definition.path}\n#{definition.content}")

      "install" ->
        File.mkdir_p!(Path.dirname(definition.path))
        File.write!(definition.path, definition.content)
        run_all(Service.load_commands(os, definition.path, uid()))
        Output.info("Serviço instalado: #{definition.path}\nLog: #{log()}")

      "uninstall" ->
        run_all(Service.unload_commands(os, definition.path, uid()))
        File.rm(definition.path)
        Output.info("Serviço removido.")
    end
  end

  def run(_args), do: Output.fail!("Uso: cp-runner service print | install | uninstall")

  # From the binary or a release the service runs cp-runner; in development, mix.
  defp options do
    {program, dir} =
      case Service.program(System.get_env()) do
        :development ->
          mix = System.find_executable("mix") || Output.fail!("mix não está no PATH")
          {[mix, "runner.start"], File.cwd!()}

        program ->
          program
      end

    [
      program: program,
      runner_dir: dir,
      config_dir: Config.dir(),
      path: System.get_env("PATH"),
      home: System.user_home!()
    ]
  end

  defp log, do: Path.join(Config.dir(), "runner.log")

  defp uid do
    {uid, 0} = System.cmd("id", ["-u"])
    uid |> String.trim() |> String.to_integer()
  end

  defp run_all(commands) do
    for [command | args] <- commands do
      case System.cmd(command, args, stderr_to_stdout: true) do
        {_output, 0} ->
          :ok

        {output, status} ->
          Output.fail!("#{command} #{Enum.join(args, " ")} falhou (#{status}): #{output}")
      end
    end
  end
end
