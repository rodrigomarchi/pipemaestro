# `mix test --cover` reports with the umbrella's tool, absent from the
# release image, which copies only the `mix.exs` files.
coverage_tool = Path.expand("../../test_coverage.exs", __DIR__)
if File.exists?(coverage_tool), do: Code.require_file(coverage_tool)

defmodule PipeMaestroWeb.MixProject do
  use Mix.Project

  def project do
    [
      app: :pipe_maestro_web,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      elixirc_options: elixirc_options(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      consolidate_protocols: Mix.env() != :test,
      test_coverage: [
        tool: PipeMaestro.TestCoverage,
        summary: [threshold: 60],
        ignore_modules: [
          PipeMaestroWeb,
          PipeMaestroWeb.Application,
          PipeMaestroWeb.ChannelCase,
          PipeMaestroWeb.ConnCase,
          PipeMaestroWeb.Telemetry
        ]
      ],
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {PipeMaestroWeb.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp elixirc_options(:prod), do: [debug_info: false, docs: false]
  defp elixirc_options(_), do: []

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.16"},
      {:phoenix_ecto, "~> 4.5"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.5", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:pipe_maestro, in_umbrella: true},
      {:bandit, "~> 1.5"},
      {:petal_components, "~> 4.17"},
      # Markdown of the agents' artifacts, rendered and sanitized on the server.
      {:mdex, "~> 0.12"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "assets.setup", "assets.build"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": [
        "compile",
        "tailwind pipe_maestro_web",
        "esbuild pipe_maestro_web"
      ],
      "assets.deploy": [
        "tailwind pipe_maestro_web --minify",
        "esbuild pipe_maestro_web --minify",
        "phx.digest"
      ]
    ]
  end
end
