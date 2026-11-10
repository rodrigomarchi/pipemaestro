defmodule PipeMaestro.Repo.Migrations.CreateIntegrationPrOutcomes do
  use Ecto.Migration

  def change do
    create table(:integration_pr_outcomes, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :task_id, references(:tasks, type: :binary_id, on_delete: :delete_all), null: false

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :linked_repo_id,
          references(:integration_repos, type: :binary_id, on_delete: :nilify_all)

      add :pr_number, :integer
      add :pr_url, :string
      add :ready_at, :utc_datetime, null: false
      add :state, :string, null: false, default: "open"
      add :merged_at, :utc_datetime
      add :closed_at, :utc_datetime
      add :review_rounds, :integer, null: false, default: 0
      add :review_keys, {:array, :string}, null: false, default: []
      add :pipeline_shas, {:array, :string}, null: false, default: []
      add :human_shas, {:array, :string}, null: false, default: []
      add :observed_head, :string
      add :commits_tracked, :boolean, null: false, default: true
      add :commits_final, :boolean, null: false, default: false
      add :commits_error, :text

      timestamps(type: :utc_datetime)
    end

    create unique_index(:integration_pr_outcomes, [:task_id])
    create index(:integration_pr_outcomes, [:workspace_id, :ready_at])

    # What the reconciliation still looks at on the host.
    create index(:integration_pr_outcomes, [:state],
             where: "state = 'open' OR commits_final = false OR commits_error IS NOT NULL",
             name: :integration_pr_outcomes_pending_index
           )
  end
end
