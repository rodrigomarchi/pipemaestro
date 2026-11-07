defmodule PipeMaestro.Repo.Migrations.AddAutoMerge do
  use Ecto.Migration

  def change do
    alter table(:pipelines) do
      add :auto_merge, :boolean, null: false, default: false
      add :merge_method, :string, null: false, default: "squash"
      add :max_merge_fixes, :integer, null: false, default: 3
    end

    alter table(:tasks) do
      add :merge_state, :string
      add :merge_fixes, :integer, null: false, default: 0
      add :merge_reason, :text
      add :merge_waiting_since, :utc_datetime
    end

    # The tasks whose pull request the platform is waiting to merge.
    create index(:tasks, [:merge_state], where: "merge_state = 'waiting_checks'")
  end
end
