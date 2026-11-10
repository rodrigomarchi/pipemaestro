defmodule PipeMaestro.Repo.Migrations.AddAutoAnalysisToPipelines do
  use Ecto.Migration

  def change do
    alter table(:pipelines) do
      add :auto_analysis, :boolean, null: false, default: true
    end
  end
end
