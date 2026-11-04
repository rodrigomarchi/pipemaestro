defmodule PipeMaestro.Repo.Migrations.AddConversationToTasks do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      # Instructions sent while a stage ran, for the next attempt or stage.
      add :pending_instructions, :text
      # Someone asked to pause once the current stage ends.
      add :pause_requested, :boolean, null: false, default: false
    end
  end
end
