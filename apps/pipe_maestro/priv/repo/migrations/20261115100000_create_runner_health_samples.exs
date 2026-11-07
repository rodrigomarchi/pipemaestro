defmodule PipeMaestro.Repo.Migrations.CreateRunnerHealthSamples do
  use Ecto.Migration

  def change do
    # What a runner's machine reported about itself, a sample a minute.
    create table(:runner_health_samples, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :runner_id, references(:runners, type: :binary_id, on_delete: :delete_all), null: false

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :at, :utc_datetime_usec, null: false
      add :cpu_pct, :float
      add :load1, :float
      add :mem_used_bytes, :bigint
      add :mem_total_bytes, :bigint
      add :disk_free_bytes, :bigint
      add :disk_total_bytes, :bigint
      add :outbox_pending, :integer
      add :running_jobs, :integer
      add :beam_bytes, :bigint
    end

    create index(:runner_health_samples, [:runner_id, :at])
    create index(:runner_health_samples, [:at])

    # A runner's finished jobs over a period (its failure rate, setup and queue).
    create index(:jobs, [:runner_id, :finished_at])
  end
end
