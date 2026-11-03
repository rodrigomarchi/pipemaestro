defmodule ClaudeControlPlane.Umbrella.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      listeners: [Phoenix.CodeReloader],
      releases: releases(),
      consolidate_protocols: Mix.env() != :test,
      dialyzer: [
        plt_local_path: "priv/plts",
        plt_core_path: "priv/plts",
        plt_add_apps: [:ex_unit, :mix],
        flags: [:no_opaque]
      ]
    ]
  end

  # The control plane and the runner ship separately: the runner is installed
  # on the customer's infrastructure and must not carry Phoenix or Ecto.
  defp releases do
    [
      # `server` (rel/control_plane/bin) migrates, then starts the web server.
      claude_control_plane: [
        applications: [
          claude_control_plane: :permanent,
          claude_control_plane_web: :permanent
        ],
        overlays: ["rel/control_plane"],
        steps: [:assemble, :tar]
      ],
      # `cp-runner` (rel/runner/bin) is the runner's command line.
      claude_control_plane_runner: [
        applications: [claude_control_plane_runner: :permanent],
        runtime_config_path: "config/runner_runtime.exs",
        overlays: ["rel/runner"],
        steps: [:assemble, :tar]
      ]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Dependencies listed here are available only for this project
  # and cannot be accessed from applications inside the apps/ folder.
  defp deps do
    [
      # Required to run "mix format" on ~H/.heex files from the umbrella root
      {:phoenix_live_view, ">= 0.0.0"},

      # Static analysis
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_dna, "~> 1.5", only: [:dev, :test], runtime: false}
    ]
  end

  # Aliases listed here are available only for this project
  # and cannot be accessed from applications inside the apps/ folder.
  defp aliases do
    [
      # run `mix setup` in all child apps
      setup: ["cmd mix setup"],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"]
    ]
  end
end
