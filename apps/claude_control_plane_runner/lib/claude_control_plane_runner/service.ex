defmodule ClaudeControlPlaneRunner.Service do
  @moduledoc """
  The runner as a background service of the user who runs it
  (`mix runner.service`): a launchd agent on macOS, a systemd user unit on
  Linux. It starts at login, runs `mix runner.start` in the runner app,
  restarts when it stops, and writes its output to `runner.log` next to the
  credentials. A restarted runner rejoins and the control plane reconciles
  its jobs (`ClaudeControlPlaneProtocol.Hello`'s `running_job_ids`).
  """

  @label "com.claude-control-plane.runner"
  @unit "claude-control-plane-runner.service"

  @typedoc "Where the service file goes and what it says."
  @type definition :: %{path: Path.t(), content: String.t()}

  @doc """
  The service file for `os` (`:os.type/0`). Options: `:runner_dir`,
  `:config_dir`, `:mix` (the executable), `:path` (the `PATH` it runs with)
  and `:home`.
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
          <string>#{opts[:mix]}</string>
          <string>runner.start</string>
        </array>
        <key>WorkingDirectory</key>
        <string>#{opts[:runner_dir]}</string>
        <key>EnvironmentVariables</key>
        <dict>
          <key>PATH</key>
          <string>#{opts[:path]}</string>
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
      Description=Runner do claude_control_plane
      After=network-online.target

      [Service]
      WorkingDirectory=#{opts[:runner_dir]}
      ExecStart=#{opts[:mix]} runner.start
      Environment=PATH=#{opts[:path]}
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
