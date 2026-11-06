defmodule PipeMaestro.Repo.Migrations.CreateIntegrations do
  use Ecto.Migration

  def change do
    # A git host connected to a workspace (docs/specs/integracoes.md).
    create table(:integration_connections, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :name, :string, null: false
      add :provider, :string, null: false
      add :base_url, :string, null: false
      add :auth_kind, :string, null: false
      add :api_mode, :string, null: false, default: "control_plane"
      # PipeMaestro.Vault blobs: the credential (a map) and the webhook's secret.
      add :encrypted_credentials, :binary
      add :encrypted_webhook_secret, :binary, null: false
      add :oauth_client_id, :string
      add :encrypted_oauth_client_secret, :binary
      add :bot_login, :string
      add :bot_user_id, :string
      add :server_version, :string
      add :status, :string, null: false, default: "pending"
      add :last_error, :text
      add :checked_at, :utc_datetime
      add :connected_by_id, references(:users, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:integration_connections, [:workspace_id, :name])

    create table(:integration_repos, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :connection_id,
          references(:integration_connections, type: :binary_id, on_delete: :delete_all),
          null: false

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :project_id, references(:projects, type: :binary_id, on_delete: :nilify_all)
      add :owner, :string, null: false
      add :name, :string, null: false
      add :full_name, :string, null: false
      add :external_id, :string
      add :default_branch, :string
      add :webhook_id, :string
      add :webhook_status, :string, null: false, default: "manual"
      add :label_prefix, :string, null: false, default: "pipemaestro"
      # Where the next reconciliation starts reading the repository's issues.
      add :synced_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:integration_repos, [:connection_id, :full_name])
    create index(:integration_repos, [:workspace_id])

    create table(:integration_triggers, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :repo_id, references(:integration_repos, type: :binary_id, on_delete: :delete_all),
        null: false

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :kind, :string, null: false
      add :label, :string
      add :command, :string
      add :mode, :string, null: false, default: "triage"
      add :auto_approve, :boolean, null: false, default: true
      add :pipeline_id, references(:pipelines, type: :binary_id, on_delete: :nilify_all)
      add :author_policy, :string, null: false, default: "writers"
      add :max_per_hour, :integer, null: false, default: 10
      add :acting_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :enabled, :boolean, null: false, default: true

      timestamps(type: :utc_datetime)
    end

    create index(:integration_triggers, [:repo_id])

    # What the platform last saw of an issue: its labels (to find the one just
    # added) and the triggers that already fired on it.
    create table(:integration_issues, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :repo_id, references(:integration_repos, type: :binary_id, on_delete: :delete_all),
        null: false

      add :number, :integer, null: false
      add :labels, {:array, :string}, null: false, default: []
      add :seen_updated_at, :utc_datetime
      add :fired, :map, null: false, default: %{}
      add :commands, {:array, :string}, null: false, default: []

      timestamps(type: :utc_datetime)
    end

    create unique_index(:integration_issues, [:repo_id, :number])

    create table(:integration_deliveries, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :connection_id,
          references(:integration_connections, type: :binary_id, on_delete: :delete_all),
          null: false

      add :source, :string, null: false
      add :external_id, :string, null: false
      add :event, :string
      add :action, :string
      add :kind, :string
      add :repo_full_name, :string
      add :issue_number, :integer
      add :payload, :map, null: false, default: %{}
      add :status, :string, null: false, default: "received"
      add :outcome, :text
      add :task_id, references(:tasks, type: :binary_id, on_delete: :nilify_all)
      add :proposal_job_id, references(:jobs, type: :binary_id, on_delete: :nilify_all)
      add :attempts, :integer, null: false, default: 0
      add :processed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:integration_deliveries, [:connection_id, :external_id])
    create index(:integration_deliveries, [:workspace_id, :inserted_at])
    create index(:integration_deliveries, [:status])

    alter table(:tasks) do
      add :linked_repo_id,
          references(:integration_repos, type: :binary_id, on_delete: :nilify_all)

      add :issue_number, :integer
      add :issue_feedback, :map, null: false, default: %{}
      add :head_sha, :string
    end

    create index(:tasks, [:linked_repo_id, :issue_number])
  end
end
