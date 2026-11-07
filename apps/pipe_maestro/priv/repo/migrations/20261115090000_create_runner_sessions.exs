defmodule PipeMaestro.Repo.Migrations.CreateRunnerSessions do
  use Ecto.Migration

  def change do
    # Each connection of a runner, from its join to its end and why it ended;
    # a refused join is one that ends as it starts.
    create table(:runner_sessions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :runner_id, references(:runners, type: :binary_id, on_delete: :delete_all), null: false

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :started_at, :utc_datetime_usec, null: false
      add :ended_at, :utc_datetime_usec
      add :end_reason, :string
      add :runner_version, :string
    end

    create index(:runner_sessions, [:runner_id, :started_at])

    create index(:runner_sessions, [:runner_id],
             where: "ended_at IS NULL",
             name: :runner_sessions_open_index
           )
  end
end
