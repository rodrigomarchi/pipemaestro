defmodule ClaudeControlPlane.Repo.Migrations.AddAgentToRunners do
  use Ecto.Migration

  def change do
    alter table(:runners) do
      # The agent CLI the runner announced: its version and how it signs in.
      add :agent, :map
    end
  end
end
