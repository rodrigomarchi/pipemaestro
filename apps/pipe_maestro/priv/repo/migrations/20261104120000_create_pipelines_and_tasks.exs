defmodule PipeMaestro.Repo.Migrations.CreatePipelinesAndTasks do
  use Ecto.Migration

  def change do
    alter table(:runners) do
      add :directories, {:array, :map}, null: false, default: []
    end

    create table(:pipelines, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :name, :string, null: false
      add :description, :text
      add :version, :integer, null: false, default: 1
      add :stages, :map, null: false, default: fragment("'[]'::jsonb")

      timestamps(type: :utc_datetime)
    end

    create unique_index(:pipelines, [:workspace_id, :name])

    create table(:tasks, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :runner_id, references(:runners, type: :binary_id, on_delete: :nilify_all)
      add :created_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :pipeline_id, references(:pipelines, type: :binary_id, on_delete: :nilify_all)
      add :pipeline_name, :string, null: false
      add :pipeline_version, :integer, null: false
      add :stages, :map, null: false, default: fragment("'[]'::jsonb")
      add :title, :string, null: false
      add :prompt, :text, null: false
      add :directory, :string, null: false
      add :git, :boolean, null: false, default: false
      add :branch, :string
      add :worktree, :string
      add :status, :string, null: false, default: "running"
      add :current_stage, :integer, null: false, default: 0
      add :decision_reason, :text
      add :finished_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:tasks, [:workspace_id, :inserted_at])

    create table(:stage_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :task_id, references(:tasks, type: :binary_id, on_delete: :delete_all), null: false
      add :index, :integer, null: false
      add :key, :string, null: false
      add :name, :string, null: false
      add :attempt, :integer, null: false
      add :instructions, :text
      add :status, :string, null: false, default: "running"
      add :summary, :text
      add :structured_output, :map
      add :artifact, :text
      add :error, :text

      timestamps(type: :utc_datetime)
    end

    create index(:stage_runs, [:task_id, :index, :attempt])

    alter table(:jobs) do
      add :stage_run_id, references(:stage_runs, type: :binary_id, on_delete: :delete_all)
      add :context, :map, null: false, default: %{}
      add :structured_output, :map
      add :artifact, :text
      add :workdir, :string
    end

    create unique_index(:jobs, [:stage_run_id])
  end
end
