defmodule PipeMaestro.Repo.Migrations.AddSelfServeSignup do
  @moduledoc """
  Self-serve sign-up (ADR 0058): a workspace's `plan` (`"custom"`, set up by an
  operator, or `"free_beta"`, created by someone who signed up) and its
  `owner_id` (who created it, counted against the plan's limit), and when each
  member saw or skipped the getting-started lesson (`onboarding_seen_at`).

  Existing workspaces stay `custom`, so none of them ever shows the lesson.
  """
  use Ecto.Migration

  def change do
    alter table(:workspaces) do
      add :plan, :string, null: false, default: "custom"
      add :owner_id, references(:users, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:workspaces, [:owner_id])

    alter table(:workspace_memberships) do
      add :onboarding_seen_at, :utc_datetime
    end
  end
end
