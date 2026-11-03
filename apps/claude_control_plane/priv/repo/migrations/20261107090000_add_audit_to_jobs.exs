defmodule ClaudeControlPlane.Repo.Migrations.AddAuditToJobs do
  use Ecto.Migration

  def change do
    # What the agent's run reported about itself (stream-json and the runner).
    alter table(:jobs) do
      add :session_id, :string
      add :cli_version, :string
      add :model, :string
      add :stop_reason, :string
      add :result_subtype, :string
      add :duration_api_ms, :integer
      add :ttft_ms, :integer
      add :wall_ms, :integer
      add :input_tokens, :bigint
      add :output_tokens, :bigint
      add :cache_read_tokens, :bigint
      add :cache_creation_tokens, :bigint
      add :thinking_tokens, :bigint
      add :model_usage, :map
      add :permission_denials, {:array, :map}
      add :subagents, :map
      add :environment, :map
      add :stderr, :text
      # The OpenTelemetry metrics summed: lines added and removed, commits...
      add :telemetry_totals, :map, null: false, default: %{}
    end

    # The CLI's OpenTelemetry events and metric increments, one row each.
    create table(:job_telemetry, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :job_id, references(:jobs, type: :binary_id, on_delete: :delete_all), null: false

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :name, :string, null: false
      add :at, :utc_datetime_usec, null: false
      add :attrs, :map, null: false, default: %{}
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:job_telemetry, [:job_id, :at])
    create index(:job_telemetry, [:workspace_id, :name, :at])
  end
end
