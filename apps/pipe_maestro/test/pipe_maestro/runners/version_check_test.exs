defmodule PipeMaestro.Runners.VersionCheckTest do
  # Changes the version policy, which is global to the VM.
  use ExUnit.Case, async: false

  alias PipeMaestro.Runners

  setup do
    previous = Application.get_env(:pipe_maestro, :runner_version_policy)
    Application.put_env(:pipe_maestro, :runner_version_policy, :exact)

    on_exit(fn -> Application.put_env(:pipe_maestro, :runner_version_policy, previous) end)
  end

  test "only a runner on the control plane's version may connect" do
    # The control plane runs as 2026-11-04.02 in tests (config/test.exs).
    assert Runners.version_check("2026-11-04.02") == :ok
    assert Runners.version_check("2026-11-04.01") == {:outdated, "2026-11-04.02"}
    assert Runners.version_check("2026-11-04.03") == {:outdated, "2026-11-04.02"}
    assert Runners.version_check("dev+abc1234") == {:outdated, "2026-11-04.02"}
    assert Runners.version_check(nil) == {:outdated, "2026-11-04.02"}
  end

  test "the policy can be turned off" do
    Application.put_env(:pipe_maestro, :runner_version_policy, :off)
    assert Runners.version_check("0.1.0") == :ok
  end
end
