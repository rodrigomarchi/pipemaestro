defmodule ClaudeControlPlane.Repo.Migrations.CreateRunners do
  use Ecto.Migration

  def change do
    create table(:runners, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :approved_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :name, :string, null: false
      add :token_hash, :binary
      add :hostname, :string
      add :os, :string
      add :arch, :string
      add :runner_version, :string
      add :labels, {:array, :string}, null: false, default: []
      add :capacity, :integer, null: false, default: 1
      add :last_connected_at, :utc_datetime
      add :last_seen_at, :utc_datetime
      add :revoked_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:runners, [:workspace_id])
    create unique_index(:runners, [:token_hash])

    create table(:runner_device_authorizations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :device_code_hash, :binary, null: false
      add :user_code, :string, null: false
      add :status, :string, null: false, default: "pending"
      add :requested, :map, null: false, default: %{}
      add :name, :string
      add :expires_at, :utc_datetime, null: false
      add :last_polled_at, :utc_datetime
      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all)
      add :approved_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :runner_id, references(:runners, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:runner_device_authorizations, [:device_code_hash])

    # Only one live request may hold a given user code at a time.
    create unique_index(:runner_device_authorizations, [:user_code],
             where: "status = 'pending'",
             name: :runner_device_authorizations_pending_user_code_index
           )
  end
end
