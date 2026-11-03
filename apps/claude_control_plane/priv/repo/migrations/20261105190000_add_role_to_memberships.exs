defmodule ClaudeControlPlane.Repo.Migrations.AddRoleToMemberships do
  use Ecto.Migration

  def up do
    alter table(:workspace_memberships) do
      add :role, :string, null: false, default: "member"
    end

    # Whoever belonged to a workspace before roles existed could do
    # everything: they stay admins.
    execute "UPDATE workspace_memberships SET role = 'admin'"
  end

  def down do
    alter table(:workspace_memberships) do
      remove :role
    end
  end
end
