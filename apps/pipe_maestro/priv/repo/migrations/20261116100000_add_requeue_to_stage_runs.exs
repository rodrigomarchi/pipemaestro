defmodule PipeMaestro.Repo.Migrations.AddRequeueToStageRuns do
  use Ecto.Migration

  def change do
    alter table(:stage_runs) do
      add :requeue, :integer, null: false, default: 0
    end
  end
end
