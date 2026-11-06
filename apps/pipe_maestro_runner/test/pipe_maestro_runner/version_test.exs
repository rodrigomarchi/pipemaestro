defmodule PipeMaestroRunner.VersionTest do
  use ExUnit.Case, async: true

  alias PipeMaestroProtocol.Version, as: Scheme
  alias PipeMaestroProtocol.Version.Git
  alias PipeMaestroRunner.Version

  test "the version is embedded at build time in the release scheme" do
    version = Version.version()

    assert is_binary(version)
    assert Scheme.parse(version) != :unknown
  end

  test "it is recompiled only when the version it would compute changes" do
    refute Version.__mix_recompile__?()
  end

  test "it is the runner's version, from the commits that changed the runner" do
    assert Version.version() == Git.runner(__DIR__)
  end

  test "the runner's paths cover this app and every umbrella app it depends on" do
    paths = Enum.map(Git.runner_paths(), &String.trim_trailing(&1, "/"))

    umbrella_apps =
      for {app, opts} when is_list(opts) <- Mix.Project.config()[:deps],
          Keyword.get(opts, :in_umbrella),
          do: app

    for app <- [Mix.Project.config()[:app] | umbrella_apps] do
      assert "apps/#{app}" in paths, "apps/#{app} goes into the runner's binary"
    end
  end
end
