defmodule PipeMaestro.Repo.Migrations.CreateNotifications do
  use Ecto.Migration

  def change do
    create table(:notifications, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :title, :string, null: false
      add :body, :text
      # Without its task or its proposal, a notification has nowhere to lead.
      add :task_id, references(:tasks, type: :binary_id, on_delete: :delete_all)
      add :job_id, references(:jobs, type: :binary_id, on_delete: :delete_all)
      add :read_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:notifications, [:user_id, :workspace_id, :read_at])
    create index(:notifications, [:user_id, :workspace_id, :inserted_at])
    create index(:notifications, [:read_at])
    create index(:notifications, [:task_id])
    create index(:notifications, [:job_id])

    # The tasks still under way in a workspace, read on every change of one.
    create index(:tasks, [:workspace_id, :status])
  end
end
