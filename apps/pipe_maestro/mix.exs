defmodule PipeMaestro.MixProject do
  use Mix.Project

  def project do
    [
      app: :pipe_maestro,
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
        summary: [threshold: 60],
        ignore_modules: [PipeMaestro.Application, PipeMaestro.DataCase]
      ]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {PipeMaestro.Application, []},
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
      {:dns_cluster, "~> 0.2.0"},
      {:phoenix_pubsub, "~> 2.4"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:bcrypt_elixir, "~> 3.0"},
      # Reading pipelines exported as YAML.
      {:yaml_elixir, "~> 2.11"},
      # The git hosts' APIs (PipeMaestro.Integrations); Plug for Req.Test.
      {:req, "~> 0.7.5"},
      {:plug, "~> 1.18", only: :test},
      {:pipe_maestro_protocol, in_umbrella: true}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run #{__DIR__}/priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"]
    ]
  end
end
