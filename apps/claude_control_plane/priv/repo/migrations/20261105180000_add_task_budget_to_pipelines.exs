defmodule ClaudeControlPlane.Repo.Migrations.AddTaskBudgetToPipelines do
  use Ecto.Migration

  def change do
    alter table(:pipelines) do
      # The most a task of the pipeline may cost before it pauses.
      add :max_task_cost_usd, :decimal
    end
  end
end
