defmodule PipeMaestro.VersionTest do
  use ExUnit.Case, async: true

  alias PipeMaestro.Version
  alias PipeMaestroProtocol.Version, as: Scheme
  alias PipeMaestroProtocol.Version.Git

  test "the build's version is embedded at compile time in the release scheme" do
    assert Scheme.parse(Version.build_version()) != :unknown
    refute Version.__mix_recompile__?()
  end

  test "the configured version, when there is one, takes the build's place" do
    assert Version.version() == "2026-11-04.02"
  end

  test "the runner's version it requires is the runner's, computed at compile time" do
    assert Scheme.parse(Version.build_runner_version()) != :unknown
    assert Version.build_runner_version() == Git.runner(__DIR__)
  end

  test "the configured runner's version, when there is one, takes the build's place" do
    # config/test.exs pins both, and they differ.
    assert Version.runner_version() == "2026-11-03.02"
    assert Version.runner_version() != Version.version()
  end
end
