defmodule PipeMaestro.Repo.Migrations.CreateJobFiles do
  use Ecto.Migration

  def change do
    # The files a job left in CP_FILES_DIR, sent by its runner.
    create table(:job_files, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :job_id, references(:jobs, type: :binary_id, on_delete: :delete_all), null: false
      add :stage_run_id, references(:stage_runs, type: :binary_id, on_delete: :delete_all)
      add :path, :text, null: false
      add :content_type, :string, null: false
      add :byte_size, :bigint, null: false
      add :sha256, :string, null: false
      add :content, :binary, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:job_files, [:job_id, :path])
    create index(:job_files, [:stage_run_id])
    create index(:job_files, [:workspace_id])

    alter table(:jobs) do
      # How many of those files the runner could not send.
      add :files_failed, :integer
    end
  end
end
