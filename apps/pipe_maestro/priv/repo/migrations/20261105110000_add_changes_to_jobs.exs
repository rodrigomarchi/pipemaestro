defmodule PipeMaestro.Repo.Migrations.AddChangesToJobs do
  use Ecto.Migration

  def change do
    alter table(:jobs) do
      # The files a task's stage changed in its worktree, and the patch.
      add :changes, :map
    end
  end
end
