defmodule PipeMaestro.Repo.Migrations.AddCapabilitiesToRunners do
  use Ecto.Migration

  def change do
    # What the runner supports beyond the protocol version (PipeMaestroProtocol.Hello).
    alter table(:runners) do
      add :capabilities, {:array, :string}, null: false, default: []
    end
  end
end
