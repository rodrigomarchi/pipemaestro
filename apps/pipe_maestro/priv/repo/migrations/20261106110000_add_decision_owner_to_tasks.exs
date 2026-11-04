defmodule PipeMaestro.Repo.Migrations.AddDecisionOwnerToTasks do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      # Who should decide on a paused task, and by when.
      add :decision_owner_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :decision_due_at, :utc_datetime
    end
  end
end
