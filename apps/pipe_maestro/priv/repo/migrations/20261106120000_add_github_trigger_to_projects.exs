defmodule PipeMaestro.Repo.Migrations.AddGithubTriggerToProjects do
  use Ecto.Migration

  def change do
    alter table(:projects) do
      # A label on an issue of this repository starts a task (GitHub webhook).
      add :github_repo, :string
      add :trigger_label, :string
      add :trigger_pipeline_id, references(:pipelines, type: :binary_id, on_delete: :nilify_all)
      # Whom the tasks the webhook starts belong to.
      add :trigger_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:projects, [:workspace_id, :github_repo])
  end
end
