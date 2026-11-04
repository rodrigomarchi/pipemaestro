defmodule PipeMaestroRunner.ServiceTest do
  use ExUnit.Case, async: true

  alias PipeMaestroRunner.Service

  @opts [
    runner_dir: "/home/ana/pipe_maestro/apps/pipe_maestro_runner",
    config_dir: "/home/ana/.config/pipemaestro",
    program: ["/home/ana/.asdf/shims/mix", "runner.start"],
    path: "/home/ana/.asdf/shims:/usr/bin:/bin",
    home: "/home/ana"
  ]

  test "a launchd agent on macOS: starts at login, restarts, logs to a file" do
    %{path: path, content: plist} = Service.definition({:unix, :darwin}, @opts)

    assert path == "/home/ana/Library/LaunchAgents/com.pipemaestro.runner.plist"
    assert plist =~ "<string>com.pipemaestro.runner</string>"

    assert plist =~
             "    <string>/home/ana/.asdf/shims/mix</string>\n    <string>runner.start</string>"

    assert plist =~
             "<key>WorkingDirectory</key>\n  <string>/home/ana/pipe_maestro/apps/pipe_maestro_runner</string>"

    assert plist =~ "<key>KeepAlive</key>\n  <true/>"
    assert plist =~ "/home/ana/.config/pipemaestro/runner.log"
    assert plist =~ "<string>/home/ana/.asdf/shims:/usr/bin:/bin</string>"
  end

  test "a systemd user unit on Linux" do
    %{path: path, content: unit} = Service.definition({:unix, :linux}, @opts)

    assert path == "/home/ana/.config/systemd/user/pipemaestro-runner.service"
    assert unit =~ "ExecStart=/home/ana/.asdf/shims/mix runner.start"

    assert unit =~
             "WorkingDirectory=/home/ana/pipe_maestro/apps/pipe_maestro_runner"

    assert unit =~ "Restart=always"
    assert unit =~ "Environment=PATH=/home/ana/.asdf/shims:/usr/bin:/bin"
    assert unit =~ "WantedBy=default.target"
  end

  test "what the service runs: the single binary, the release's pipemaestro, or mix" do
    assert Service.program(%{
             "__BURRITO_BIN_PATH" => "/opt/cp/pipemaestro",
             "RELEASE_ROOT" => "/x"
           }) ==
             {["/opt/cp/pipemaestro", "start"], "/opt/cp"}

    assert Service.program(%{"RELEASE_ROOT" => "/rel"}) ==
             {["/rel/bin/pipemaestro", "start"], "/rel"}

    assert Service.program(%{}) == :development
  end

  test "the commands that load and unload it" do
    assert Service.load_commands({:unix, :darwin}, "/x.plist", 501) ==
             [["launchctl", "bootstrap", "gui/501", "/x.plist"]]

    assert Service.unload_commands({:unix, :darwin}, "/x.plist", 501) ==
             [["launchctl", "bootout", "gui/501", "/x.plist"]]

    assert Service.load_commands({:unix, :linux}, "/u.service", 1000) == [
             ["systemctl", "--user", "daemon-reload"],
             ["systemctl", "--user", "enable", "--now", "pipemaestro-runner.service"]
           ]
  end
end
