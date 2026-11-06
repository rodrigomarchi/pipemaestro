defmodule PipeMaestro.Repo.Migrations.GithubAppAndLegacyTriggers do
  use Ecto.Migration

  # The GitHub trigger a project kept (ADR 0014) becomes an integration (ADR
  # 0034): per workspace, a GitHub connection waiting for the App to be
  # installed, and per project a linked repository with a label trigger.
  def up do
    alter table(:integration_connections) do
      # A GitHub App's installation, which its webhooks name.
      add :external_account_id, :string
      modify :encrypted_webhook_secret, :binary, null: true
    end

    create index(:integration_connections, [:provider, :external_account_id])

    execute """
    INSERT INTO integration_connections
      (id, workspace_id, name, provider, base_url, auth_kind, api_mode, status, last_error,
       inserted_at, updated_at)
    SELECT gen_random_uuid(), p.workspace_id, 'GitHub', 'github', 'https://github.com',
           'github_app', 'control_plane', 'pending',
           'Instale o GitHub App para os gatilhos que vieram dos projetos voltarem a funcionar.',
           now(), now()
    FROM (SELECT DISTINCT workspace_id FROM projects
          WHERE github_repo IS NOT NULL AND trigger_label IS NOT NULL) p
    ON CONFLICT (workspace_id, name) DO NOTHING
    """

    execute """
    INSERT INTO integration_repos
      (id, connection_id, workspace_id, project_id, owner, name, full_name, webhook_status,
       label_prefix, inserted_at, updated_at)
    SELECT gen_random_uuid(), c.id, p.workspace_id, p.id,
           split_part(lower(p.github_repo), '/', 1), split_part(lower(p.github_repo), '/', 2),
           lower(p.github_repo), 'app', 'pipemaestro', now(), now()
    FROM projects p
    JOIN integration_connections c
      ON c.workspace_id = p.workspace_id AND c.provider = 'github' AND c.name = 'GitHub'
    WHERE p.github_repo IS NOT NULL AND p.trigger_label IS NOT NULL
    ON CONFLICT (connection_id, full_name) DO NOTHING
    """

    # A legacy triage waited for review: it keeps doing so.
    execute """
    INSERT INTO integration_triggers
      (id, repo_id, workspace_id, kind, label, mode, auto_approve, pipeline_id, author_policy,
       max_per_hour, acting_user_id, enabled, inserted_at, updated_at)
    SELECT gen_random_uuid(), r.id, p.workspace_id, 'label', p.trigger_label, p.trigger_mode,
           false, p.trigger_pipeline_id, 'writers', 10, p.trigger_user_id, true, now(), now()
    FROM projects p
    JOIN integration_repos r ON r.project_id = p.id AND r.full_name = lower(p.github_repo)
    WHERE p.github_repo IS NOT NULL AND p.trigger_label IS NOT NULL
    """

    drop index(:projects, [:workspace_id, :github_repo])

    alter table(:projects) do
      remove :github_repo
      remove :trigger_label
      remove :trigger_mode
      remove :trigger_pipeline_id
      remove :trigger_user_id
    end
  end

  def down do
    alter table(:projects) do
      add :github_repo, :string
      add :trigger_label, :string
      add :trigger_mode, :string, null: false, default: "task"
      add :trigger_pipeline_id, references(:pipelines, type: :binary_id, on_delete: :nilify_all)
      add :trigger_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:projects, [:workspace_id, :github_repo])
    drop index(:integration_connections, [:provider, :external_account_id])

    alter table(:integration_connections) do
      remove :external_account_id
    end
  end
end
