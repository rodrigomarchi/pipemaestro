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
      ],
      # The same runner as a single binary per platform (Burrito, in
      # burrito_out/): `cp_runner_<alvo> <comando>`, nothing to install first.
      cp_runner: [
        version: binary_version(),
        applications: [claude_control_plane_runner: :permanent],
        runtime_config_path: "config/runner_runtime.exs",
        steps: [:assemble, &Burrito.wrap/1],
        burrito: [
          # The runner has no NIFs; Burrito would otherwise rebuild every NIF
          # of the umbrella (bcrypt, of the control plane) for each target.
          targets: [
            macos_arm64: [os: :darwin, cpu: :aarch64, skip_nifs: true],
            macos_x86_64: [os: :darwin, cpu: :x86_64, skip_nifs: true],
            linux_x86_64: [os: :linux, cpu: :x86_64, skip_nifs: true],
            linux_arm64: [os: :linux, cpu: :aarch64, skip_nifs: true]
          ]
        ]
      ]
    ]
  end

  # A binary unpacks itself once per version: the commit in it makes each
  # build a new one, so an updated binary never runs an older payload.
  defp binary_version do
    case System.cmd("git", ["rev-parse", "--short", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> "0.1.0+#{String.trim(sha)}"
      _no_git -> "0.1.0"
    end
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

      # Builds the runner's single binary (the cp_runner release)
      {:burrito, "~> 1.6", runtime: false},

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
