defmodule ClaudeControlPlane.Repo.Migrations.AddSetupToJobs do
  use Ecto.Migration

  def change do
    alter table(:jobs) do
      # How the runner set up the task's worktree when this job created it.
      add :setup, :map
    end
  end
end
