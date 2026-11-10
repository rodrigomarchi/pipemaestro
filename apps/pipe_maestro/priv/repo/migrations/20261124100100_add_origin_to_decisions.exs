defmodule PipeMaestro.Repo.Migrations.AddOriginToDecisions do
  use Ecto.Migration

  def up do
    alter table(:decisions) do
      add :origin, :string
    end

    flush()

    # Corrections from before the origin was kept: the automatic merge signs
    # its own; any other one is counted as a person's.
    execute """
    UPDATE decisions SET origin = CASE
      WHEN decided_via = 'merge automático' THEN 'auto_merge'
      ELSE 'person'
    END
    WHERE action = 'correct'
    """
  end

  def down do
    alter table(:decisions) do
      remove :origin
    end
  end
end
