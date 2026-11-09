defmodule PipeMaestro.Repo.Migrations.AddSessionTotalsToJobs do
  use Ecto.Migration

  def change do
    # What the CLI reported for the whole session, before the session the job
    # resumed was taken out of its cost (`PipeMaestro.Jobs.SessionTotals`).
    alter table(:jobs) do
      add :session_totals, :map
    end
  end
end
