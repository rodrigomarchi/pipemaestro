defmodule PipeMaestro.Repo.Migrations.AddDecisionQuestionnaire do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      add :decision_questionnaire, :map
      add :decision_analysis_job_id, references(:jobs, type: :binary_id, on_delete: :nilify_all)
    end

    alter table(:decisions) do
      add :questions, :map
      add :answers, :map
    end

    alter table(:stage_runs) do
      add :answers, :map
    end
  end
end
