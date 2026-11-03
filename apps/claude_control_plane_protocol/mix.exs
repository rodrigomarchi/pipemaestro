defmodule ClaudeControlPlaneProtocol.MixProject do
  use Mix.Project

  def project do
    [
      app: :claude_control_plane_protocol,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.20",
      elixirc_options: elixirc_options(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      consolidate_protocols: Mix.env() != :test,
      test_coverage: [summary: [threshold: 60]]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_options(:prod), do: [debug_info: false, docs: false]
  defp elixirc_options(_), do: []

  # The contract is shared by the control plane and the runner, so it depends
  # on neither of them and carries no Phoenix or Ecto.
  defp deps do
    []
  end
end
