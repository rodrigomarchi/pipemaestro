defmodule PipeMaestro.Repo.Migrations.AddSessionResumedToJobs do
  use Ecto.Migration

  def change do
    alter table(:jobs) do
      # Whether a job that asked to resume the previous stage's session did
      # (null: it asked for none).
      add :session_resumed, :boolean
    end
  end
end
