defmodule PipeMaestro.Repo.Migrations.AddMaxRunningTasksToWorkspaces do
  use Ecto.Migration

  def change do
    alter table(:workspaces) do
      # How many tasks may run at once; past it new ones wait in line. No limit when null.
      add :max_running_tasks, :integer
    end
  end
end
