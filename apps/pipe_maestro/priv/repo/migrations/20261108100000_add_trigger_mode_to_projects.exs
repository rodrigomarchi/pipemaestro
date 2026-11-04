defmodule PipeMaestro.Repo.Migrations.AddTriggerModeToProjects do
  use Ecto.Migration

  def change do
    # What a labeled issue does: start a task, or have the agent triage it first.
    alter table(:projects) do
      add :trigger_mode, :string, null: false, default: "task"
    end
  end
end
