defmodule ClaudeControlPlaneRunner.ServiceTest do
  use ExUnit.Case, async: true

  alias ClaudeControlPlaneRunner.Service

  @opts [
    runner_dir: "/home/ana/claude_control_plane/apps/claude_control_plane_runner",
    config_dir: "/home/ana/.config/claude-control-plane",
    mix: "/home/ana/.asdf/shims/mix",
    path: "/home/ana/.asdf/shims:/usr/bin:/bin",
    home: "/home/ana"
  ]

  test "a launchd agent on macOS: starts at login, restarts, logs to a file" do
    %{path: path, content: plist} = Service.definition({:unix, :darwin}, @opts)

    assert path == "/home/ana/Library/LaunchAgents/com.claude-control-plane.runner.plist"
    assert plist =~ "<string>com.claude-control-plane.runner</string>"
    assert plist =~ "<string>/home/ana/.asdf/shims/mix</string>"
    assert plist =~ "<string>runner.start</string>"

    assert plist =~
             "<key>WorkingDirectory</key>\n  <string>/home/ana/claude_control_plane/apps/claude_control_plane_runner</string>"

    assert plist =~ "<key>KeepAlive</key>\n  <true/>"
    assert plist =~ "/home/ana/.config/claude-control-plane/runner.log"
    assert plist =~ "<string>/home/ana/.asdf/shims:/usr/bin:/bin</string>"
  end

  test "a systemd user unit on Linux" do
    %{path: path, content: unit} = Service.definition({:unix, :linux}, @opts)

    assert path == "/home/ana/.config/systemd/user/claude-control-plane-runner.service"
    assert unit =~ "ExecStart=/home/ana/.asdf/shims/mix runner.start"

    assert unit =~
             "WorkingDirectory=/home/ana/claude_control_plane/apps/claude_control_plane_runner"

    assert unit =~ "Restart=always"
    assert unit =~ "Environment=PATH=/home/ana/.asdf/shims:/usr/bin:/bin"
    assert unit =~ "WantedBy=default.target"
  end

  test "the commands that load and unload it" do
    assert Service.load_commands({:unix, :darwin}, "/x.plist", 501) ==
             [["launchctl", "bootstrap", "gui/501", "/x.plist"]]

    assert Service.unload_commands({:unix, :darwin}, "/x.plist", 501) ==
             [["launchctl", "bootout", "gui/501", "/x.plist"]]

    assert Service.load_commands({:unix, :linux}, "/u.service", 1000) == [
             ["systemctl", "--user", "daemon-reload"],
             ["systemctl", "--user", "enable", "--now", "claude-control-plane-runner.service"]
           ]
  end
end
