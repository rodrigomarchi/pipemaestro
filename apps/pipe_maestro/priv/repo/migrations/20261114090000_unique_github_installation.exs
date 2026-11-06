defmodule PipeMaestro.Repo.Migrations.UniqueGithubInstallation do
  use Ecto.Migration

  # A GitHub App installation belongs to one connection: its webhooks and
  # tokens must not reach another workspace. An installation already taken by
  # more than one connection stays with the oldest; the others lose it and
  # wait, in error, to be installed again.
  def up do
    execute """
    UPDATE integration_connections c
    SET external_account_id = NULL, status = 'error',
        last_error = 'Esta instalação do GitHub App já pertence a outra conexão; instale de novo.'
    WHERE c.external_account_id IS NOT NULL
      AND EXISTS (
        SELECT 1 FROM integration_connections o
        WHERE o.provider = c.provider AND o.external_account_id = c.external_account_id
          AND (o.inserted_at, o.id) < (c.inserted_at, c.id)
      )
    """

    drop index(:integration_connections, [:provider, :external_account_id])
    create unique_index(:integration_connections, [:provider, :external_account_id])
  end

  def down do
    drop index(:integration_connections, [:provider, :external_account_id])
    create index(:integration_connections, [:provider, :external_account_id])
  end
end
