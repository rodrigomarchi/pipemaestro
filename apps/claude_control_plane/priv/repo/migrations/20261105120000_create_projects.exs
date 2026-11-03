defmodule ClaudeControlPlane.Repo.Migrations.CreateProjects do
  use Ecto.Migration

  def change do
    create table(:projects, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :name, :string, null: false
      add :directory, :string, null: false
      add :setup_command, :text
      add :test_command, :text
      add :lint_command, :text
      add :copy_paths, {:array, :string}, null: false, default: []
      add :notes, :text

      timestamps(type: :utc_datetime)
    end

    create unique_index(:projects, [:workspace_id, :directory])

    alter table(:tasks) do
      add :project_id, references(:projects, type: :binary_id, on_delete: :nilify_all)
      # The project's settings when the task started.
      add :project, :map
    end
  end
end
