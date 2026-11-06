defmodule PipeMaestro.Repo.Migrations.CreateRunnerLogsAndEvents do
  use Ecto.Migration

  def change do
    alter table(:workspaces) do
      # How many days the runners' log lines are kept; 0 keeps none (only events).
      add :runner_log_retention_days, :integer, null: false, default: 7
    end

    # The runners' own log, as they sent it (secrets already redacted).
    create table(:runner_log_lines, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :runner_id, references(:runners, type: :binary_id, on_delete: :delete_all), null: false

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :at, :utc_datetime_usec, null: false
      add :level, :string, null: false
      add :message, :text, null: false
      add :event, :string
    end

    create index(:runner_log_lines, [:runner_id, :at])
    create index(:runner_log_lines, [:workspace_id, :at])

    # What happened to a runner apart from its jobs' work: an update, a setup
    # or a delivery that failed, a dropped connection...
    create table(:runner_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :runner_id, references(:runners, type: :binary_id, on_delete: :delete_all), null: false

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :at, :utc_datetime_usec, null: false
      add :kind, :string, null: false
      add :level, :string, null: false
      add :message, :text, null: false
      add :attrs, :map, null: false, default: %{}
      add :job_id, :binary_id
      add :task_id, :binary_id
    end

    create index(:runner_events, [:runner_id, :at])
    create index(:runner_events, [:at])
  end
end
