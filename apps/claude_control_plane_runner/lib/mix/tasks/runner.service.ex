defmodule Mix.Tasks.Runner.Service do
  @shortdoc "Installs, removes or shows the runner as a background service"
  @moduledoc """
  Runs the runner in the background as a service of the current user
  (`ClaudeControlPlaneRunner.Service`): a launchd agent on macOS, a systemd
  user unit on Linux. It uses the saved credentials and root, so sign in and
  start once by hand first (`mix runner.login`, `mix runner.start --root`).

      mix runner.service print       # shows the service file
      mix runner.service install     # writes it and starts the service
      mix runner.service uninstall   # stops the service and removes the file

  The output goes to `runner.log` next to the credentials.
  """
  use Mix.Task

  alias ClaudeControlPlaneRunner.{CLI, Config, Service}

  @impl Mix.Task
  def run([action]) when action in ["print", "install", "uninstall"] do
    CLI.start!()
    _config = CLI.config!()
    os = :os.type()
    definition = Service.definition(os, options())

    case action do
      "print" ->
        Mix.shell().info("# #{definition.path}\n#{definition.content}")

      "install" ->
        File.mkdir_p!(Path.dirname(definition.path))
        File.write!(definition.path, definition.content)
        run_all(Service.load_commands(os, definition.path, uid()))
        Mix.shell().info("Serviço instalado: #{definition.path}\nLog: #{log()}")

      "uninstall" ->
        run_all(Service.unload_commands(os, definition.path, uid()))
        File.rm(definition.path)
        Mix.shell().info("Serviço removido.")
    end
  end

  def run(_args), do: Mix.raise("Uso: mix runner.service print | install | uninstall")

  defp options do
    [
      runner_dir: File.cwd!(),
      config_dir: Config.dir(),
      mix: System.find_executable("mix") || Mix.raise("mix não está no PATH"),
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
          Mix.raise("#{command} #{Enum.join(args, " ")} falhou (#{status}): #{output}")
      end
    end
  end
end
