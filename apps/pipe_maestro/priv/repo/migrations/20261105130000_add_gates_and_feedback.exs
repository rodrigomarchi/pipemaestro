defmodule PipeMaestro.Repo.Migrations.AddGatesAndFeedback do
  use Ecto.Migration

  def change do
    alter table(:jobs) do
      # The stage's gate commands as the runner ran them, with their results.
      add :gates, {:array, :map}
    end

    alter table(:stage_runs) do
      # What went wrong in the previous attempt, given to this one.
      add :feedback, :text
    end
  end
end
