defmodule PipeMaestro.Repo.Migrations.CreateWorkspaceSecrets do
  use Ecto.Migration

  def change do
    create table(:workspace_secrets, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :name, :string, null: false
      # AES-256-GCM: IV, tag and ciphertext.
      add :encrypted_value, :binary, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:workspace_secrets, [:workspace_id, :name])
  end
end
