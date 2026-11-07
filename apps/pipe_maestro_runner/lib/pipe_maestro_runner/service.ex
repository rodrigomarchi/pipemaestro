defmodule PipeMaestroRunner.Service do
  @moduledoc """
  The runner as a background service of the user who runs it
  (`mix runner.service`): a launchd agent on macOS, a systemd user unit on
  Linux. It starts at login, runs the runner (`pipemaestro start` from a
  release, or `mix runner.start` in the runner app), restarts when it stops, and writes its output to `runner.log` next to the
  credentials. A restarted runner rejoins and the control plane reconciles
  its jobs (`PipeMaestroProtocol.Hello`'s `running_job_ids`).
  """

  @label "com.pipemaestro.runner"
  @unit "pipemaestro-runner.service"

  @typedoc "Where the service file goes and what it says."
  @type definition :: %{path: Path.t(), content: String.t()}

  @doc """
  What the service runs and where, from the environment: the single binary
  itself (Burrito's `__BURRITO_BIN_PATH`; its unpacked release has no
  `pipemaestro`), which updates itself by default when the platform is on
  another version, the release's `bin/pipemaestro`, or
  `:development` (mix).
  """
  @spec program(%{String.t() => String.t()}) :: {[String.t()], String.t()} | :development
  def program(%{"__BURRITO_BIN_PATH" => bin}),
    do: {[bin, "start"], Path.dirname(bin)}

  def program(%{"RELEASE_ROOT" => root}),
    do: {[Path.join([root, "bin", "pipemaestro"]), "start"], root}

  def program(_env), do: :development

  @doc """
  The service file for `os` (`:os.type/0`). Options: `:program` (the command
  that runs the runner, as a list), `:runner_dir` (where it runs),
  `:config_dir`, `:path` (the `PATH` it runs with) and `:home`.
  """
  @spec definition({atom(), atom()}, keyword()) :: definition()
  def definition({:unix, :darwin}, opts) do
    log = Path.join(opts[:config_dir], "runner.log")

    %{
      path: Path.join([opts[:home], "Library", "LaunchAgents", @label <> ".plist"]),
      content: """
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0">
      <dict>
        <key>Label</key>
        <string>#{@label}</string>
        <key>ProgramArguments</key>
        <array>
      #{Enum.map_join(opts[:program], "\n", &"    <string>#{&1}</string>")}
        </array>
        <key>WorkingDirectory</key>
        <string>#{opts[:runner_dir]}</string>
        <key>EnvironmentVariables</key>
        <dict>
          <key>PATH</key>
          <string>#{opts[:path]}</string>
          <key>PIPEMAESTRO_SERVICE</key>
          <string>1</string>
        </dict>
        <key>RunAtLoad</key>
        <true/>
        <key>KeepAlive</key>
        <true/>
        <key>StandardOutPath</key>
        <string>#{log}</string>
        <key>StandardErrorPath</key>
        <string>#{log}</string>
      </dict>
      </plist>
      """
    }
  end

  def definition({:unix, _linux}, opts) do
    %{
      path: Path.join([opts[:home], ".config", "systemd", "user", @unit]),
      content: """
      [Unit]
      Description=Runner do PipeMaestro
      After=network-online.target

      [Service]
      WorkingDirectory=#{opts[:runner_dir]}
      ExecStart=#{Enum.join(opts[:program], " ")}
      Environment=PATH=#{opts[:path]}
      Environment=PIPEMAESTRO_SERVICE=1
      Restart=always
      RestartSec=5
      StandardOutput=append:#{Path.join(opts[:config_dir], "runner.log")}
      StandardError=append:#{Path.join(opts[:config_dir], "runner.log")}

      [Install]
      WantedBy=default.target
      """
    }
  end

  @doc "The commands that start the service from its file, for user `uid`."
  @spec load_commands({atom(), atom()}, Path.t(), non_neg_integer()) :: [[String.t()]]
  def load_commands({:unix, :darwin}, path, uid),
    do: [["launchctl", "bootstrap", "gui/#{uid}", path]]

  def load_commands({:unix, _linux}, _path, _uid),
    do: [
      ["systemctl", "--user", "daemon-reload"],
      ["systemctl", "--user", "enable", "--now", @unit]
    ]

  @doc "The commands that stop the service and keep it from starting again."
  @spec unload_commands({atom(), atom()}, Path.t(), non_neg_integer()) :: [[String.t()]]
  def unload_commands({:unix, :darwin}, path, uid),
    do: [["launchctl", "bootout", "gui/#{uid}", path]]

  def unload_commands({:unix, _linux}, _path, _uid),
    do: [["systemctl", "--user", "disable", "--now", @unit]]
end
