defmodule ClaudeControlPlane.Repo.Migrations.AddWorktreeLifecycle do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      add :worktree_removal_requested_at, :utc_datetime
      add :worktree_removed_at, :utc_datetime
      add :worktree_error, :text
    end

    alter table(:runners) do
      # The last `worktree:usage` the runner reported.
      add :worktree_usage, :map
    end
  end
end
