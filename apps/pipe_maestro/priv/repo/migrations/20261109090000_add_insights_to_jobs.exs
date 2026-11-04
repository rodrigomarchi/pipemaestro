defmodule PipeMaestro.Repo.Migrations.AddInsightsToJobs do
  use Ecto.Migration

  def change do
    # The run's summary (PipeMaestro.Insights.summarize/1), kept past the
    # retention of its events and OpenTelemetry records.
    alter table(:jobs) do
      add :insights, :map
    end

    # The run's tools, one row each, to add up across jobs.
    create table(:job_tool_stats, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :job_id, references(:jobs, type: :binary_id, on_delete: :delete_all), null: false

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :name, :string, null: false
      add :calls, :integer, null: false, default: 0
      add :errors, :integer, null: false, default: 0
      add :denied, :integer, null: false, default: 0
      add :total_ms, :integer, null: false, default: 0
      add :measured, :integer, null: false, default: 0
    end

    create index(:job_tool_stats, [:job_id])
    create index(:job_tool_stats, [:workspace_id])

    # The account's usage limits, as the last run on the runner saw them.
    alter table(:runners) do
      add :rate_limit, :map
    end
  end
end
