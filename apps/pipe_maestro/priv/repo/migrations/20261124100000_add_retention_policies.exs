defmodule PipeMaestro.Repo.Migrations.AddRetentionPolicies do
  use Ecto.Migration

  def up do
    # Each workspace's retention (ADR 0054): how long its files keep their
    # content and how much they may take, and how long its agent's events stay
    # whole once their job ended, then what is left of them.
    alter table(:workspaces) do
      add :job_files_retention_days, :integer
      add :job_files_quota_mib, :integer
      add :agent_events_retention_days, :integer, null: false, default: 30
      add :agent_events_after_retention, :string, null: false, default: "metadata"
    end

    create constraint(:workspaces, :job_files_retention_days_range,
             check:
               "job_files_retention_days IS NULL OR job_files_retention_days BETWEEN 1 AND 3650"
           )

    create constraint(:workspaces, :job_files_quota_mib_positive,
             check: "job_files_quota_mib IS NULL OR job_files_quota_mib > 0"
           )

    create constraint(:workspaces, :agent_events_retention_days_range,
             check: "agent_events_retention_days BETWEEN 1 AND 3650"
           )

    create constraint(:workspaces, :agent_events_after_retention_values,
             check: "agent_events_after_retention IN ('metadata', 'delete')"
           )

    alter table(:jobs) do
      add :events_pruned_at, :utc_datetime
      add :files_refused_quota, :integer, null: false, default: 0
    end

    alter table(:job_files) do
      add :pruned_at, :utc_datetime
      modify :content, :binary, null: true
    end

    create index(:job_files, [:workspace_id, :inserted_at], where: "pruned_at IS NULL")
    create index(:jobs, [:finished_at], where: "events_pruned_at IS NULL")

    # The jobs the global retention already emptied (no events, no records):
    # their kept summary is final, so they count as pruned.
    execute """
    UPDATE jobs SET events_pruned_at = now()
    WHERE finished_at < now() - interval '30 days'
      AND NOT EXISTS (SELECT 1 FROM job_events e WHERE e.job_id = jobs.id)
      AND NOT EXISTS (SELECT 1 FROM job_telemetry t WHERE t.job_id = jobs.id)
    """
  end

  def down do
    drop index(:jobs, [:finished_at])
    drop index(:job_files, [:workspace_id, :inserted_at])

    execute "DELETE FROM job_files WHERE content IS NULL"

    alter table(:job_files) do
      remove :pruned_at
      modify :content, :binary, null: false
    end

    alter table(:jobs) do
      remove :events_pruned_at
      remove :files_refused_quota
    end

    drop constraint(:workspaces, :agent_events_after_retention_values)
    drop constraint(:workspaces, :agent_events_retention_days_range)
    drop constraint(:workspaces, :job_files_quota_mib_positive)
    drop constraint(:workspaces, :job_files_retention_days_range)

    alter table(:workspaces) do
      remove :job_files_retention_days
      remove :job_files_quota_mib
      remove :agent_events_retention_days
      remove :agent_events_after_retention
    end
  end
end
