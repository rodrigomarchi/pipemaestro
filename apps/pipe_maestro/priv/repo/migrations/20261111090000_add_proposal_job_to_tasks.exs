defmodule PipeMaestro.Repo.Migrations.AddProposalJobToTasks do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      add :proposal_job_id, references(:jobs, type: :binary_id, on_delete: :nilify_all)
    end

    create unique_index(:tasks, [:proposal_job_id], where: "proposal_job_id IS NOT NULL")
  end
end
