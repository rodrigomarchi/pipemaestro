defmodule PipeMaestro.Repo.Migrations.AddDecidedViaToDecisions do
  use Ecto.Migration

  def change do
    # A decision taken by a comment on a git host: the provider and the login there.
    alter table(:decisions) do
      add :decided_via, :string
    end
  end
end
