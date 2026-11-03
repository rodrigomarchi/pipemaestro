defmodule ClaudeControlPlane.Repo.Migrations.CreateDecisions do
  use Ecto.Migration

  def change do
    create table(:decisions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :task_id, references(:tasks, type: :binary_id, on_delete: :delete_all), null: false
      add :decided_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :stage_index, :integer, null: false
      add :question, :text
      add :options, {:array, :string}, null: false, default: []
      add :action, :string, null: false
      add :choice, :text
      add :instructions, :text

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:decisions, [:task_id])
  end
end
