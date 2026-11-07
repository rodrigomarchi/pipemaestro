defmodule PipeMaestro.Repo.Migrations.AddDoctorToRunners do
  use Ecto.Migration

  def change do
    alter table(:runners) do
      # The runner's latest diagnosis: when, its checks and the request it answered.
      add :doctor, :map
    end
  end
end
