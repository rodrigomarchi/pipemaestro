defmodule PipeMaestroRunner.VersionTest do
  use ExUnit.Case, async: true

  alias PipeMaestroProtocol.Version, as: Scheme
  alias PipeMaestroRunner.Version

  test "the version is embedded at build time in the release scheme" do
    version = Version.version()

    assert is_binary(version)
    assert Scheme.parse(version) != :unknown
  end

  test "it is recompiled only when the version it would compute changes" do
    refute Version.__mix_recompile__?()
  end
end
