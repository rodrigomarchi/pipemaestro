defmodule ClaudeControlPlaneRunner.MixProject do
  use Mix.Project

  def project do
    [
      app: :claude_control_plane_runner,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.20",
      elixirc_options: elixirc_options(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      consolidate_protocols: Mix.env() != :test,
      test_coverage: [
        summary: [threshold: 60],
        ignore_modules: [ClaudeControlPlaneRunner.Application]
      ]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {ClaudeControlPlaneRunner.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp elixirc_options(:prod), do: [debug_info: false, docs: false]
  defp elixirc_options(_), do: []

  # The runner is installed on the customer's infrastructure: it reaches the
  # control plane only through the protocol and never depends on its apps.
  defp deps do
    [
      {:claude_control_plane_protocol, in_umbrella: true}
    ]
  end

  # `mix setup` at the umbrella root runs `setup` in every child app.
  defp aliases do
    [setup: ["deps.get"]]
  end
end
