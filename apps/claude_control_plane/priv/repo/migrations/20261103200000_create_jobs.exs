defmodule ClaudeControlPlane.Repo.Migrations.CreateJobs do
  use Ecto.Migration

  def change do
    create table(:jobs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :runner_id, references(:runners, type: :binary_id, on_delete: :nilify_all)
      add :created_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :prompt, :text, null: false
      add :status, :string, null: false, default: "queued"
      add :exit_code, :integer
      add :result, :text
      add :error, :text
      add :cost_usd, :decimal
      add :duration_ms, :integer
      add :num_turns, :integer
      add :started_at, :utc_datetime
      add :finished_at, :utc_datetime
      add :cancel_requested_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:jobs, [:workspace_id, :inserted_at])
    create index(:jobs, [:runner_id, :status])

    create table(:job_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :job_id, references(:jobs, type: :binary_id, on_delete: :delete_all), null: false
      add :seq, :integer, null: false
      add :type, :string, null: false
      add :data, :map, null: false, default: %{}

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:job_events, [:job_id, :seq])
  end
end
