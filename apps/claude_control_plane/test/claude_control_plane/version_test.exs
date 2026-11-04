defmodule ClaudeControlPlane.VersionTest do
  use ExUnit.Case, async: true

  alias ClaudeControlPlane.Version
  alias ClaudeControlPlaneProtocol.Version, as: Scheme

  test "the build's version is embedded at compile time in the release scheme" do
    assert Scheme.parse(Version.build_version()) != :unknown
    refute Version.__mix_recompile__?()
  end

  test "the configured version, when there is one, takes the build's place" do
    assert Version.version() == "2026-11-04.02"
  end
end
