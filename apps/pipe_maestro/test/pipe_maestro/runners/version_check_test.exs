defmodule PipeMaestro.Runners.VersionCheckTest do
  # Changes the version policy, which is global to the VM.
  use ExUnit.Case, async: false

  alias PipeMaestro.Runners
  alias PipeMaestro.Runners.Runner

  # In tests (config/test.exs) the control plane runs as 2026-11-04.02 and
  # requires runners on 2026-11-03.02.
  @runner_version "2026-11-03.02"
  @control_plane "2026-11-04.02"

  setup do
    previous = Application.get_env(:pipe_maestro, :runner_version_policy)
    Application.put_env(:pipe_maestro, :runner_version_policy, :exact)

    on_exit(fn -> Application.put_env(:pipe_maestro, :runner_version_policy, previous) end)
  end

  test "only a runner on the runner's version the control plane requires may connect" do
    assert Runners.version_check(@runner_version) == :ok
    assert Runners.version_check("2026-11-03.01") == {:outdated, @runner_version}
    assert Runners.version_check("2026-11-03.03") == {:outdated, @runner_version}
    assert Runners.version_check("dev+abc1234") == {:outdated, @runner_version}
    assert Runners.version_check(nil) == {:outdated, @runner_version}
  end

  test "the control plane's own version is not the runner's, when they differ" do
    assert Runners.version_check(@control_plane) == {:outdated, @runner_version}
  end

  test "a runner is outdated when older than the runner's version required" do
    assert Runners.outdated?(%Runner{runner_version: "2026-11-03.01"})
    refute Runners.outdated?(%Runner{runner_version: @runner_version})
    # Older than the control plane, but not than the runner it requires.
    refute Runners.outdated?(%Runner{runner_version: "2026-11-04.01"})
  end

  test "the policy can be turned off" do
    Application.put_env(:pipe_maestro, :runner_version_policy, :off)
    assert Runners.version_check("0.1.0") == :ok
  end
end
