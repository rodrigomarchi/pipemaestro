defmodule ClaudeControlPlane.Release do
  @moduledoc """
  Tasks for a running release, where Mix is not available:

      bin/claude_control_plane eval 'ClaudeControlPlane.Release.migrate()'
      bin/claude_control_plane eval 'ClaudeControlPlane.Release.create_operator("ops@example.com", "Ops", "a long password")'
  """

  alias ClaudeControlPlane.Backoffice

  @app :claude_control_plane

  @doc "Runs every pending migration."
  @spec migrate() :: :ok
  def migrate do
    Application.ensure_all_started(:ssl)
    Application.load(@app)

    for repo <- Application.fetch_env!(@app, :ecto_repos) do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    :ok
  end

  @doc """
  Creates a backoffice operator. This is how the first operator comes to exist:
  every later one can be created from the backoffice itself.
  """
  @spec create_operator(String.t(), String.t(), String.t()) ::
          {:ok, Backoffice.Operator.t()} | {:error, Ecto.Changeset.t()}
  def create_operator(email, name, password) do
    Application.ensure_all_started(@app)
    Backoffice.create_operator(%{email: email, name: name, password: password})
  end
end
