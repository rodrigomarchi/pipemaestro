defmodule PipeMaestro.Repo.Migrations.AddRunnerToProjects do
  @moduledoc """
  A project becomes a runner and a directory it offers: `projects.runner_id`,
  unique per `(workspace, runner, directory)`, and a GitHub repository
  triggers at most one project of a workspace. Jobs name their project
  (`jobs.project_id`).

  Each existing project gets the workspace's active runner that offers its
  directory, the one seen last; with none it stays without a runner and
  takes no work until it gets one. Existing jobs get the project of their
  task, or of the directory they studied when exactly one project has it.
  """
  use Ecto.Migration

  def up do
    alter table(:projects) do
      add :runner_id, references(:runners, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:projects, [:runner_id])

    flush()
    execute(backfill_projects_sql())

    drop_if_exists unique_index(:projects, [:workspace_id, :directory])
    create unique_index(:projects, [:workspace_id, :runner_id, :directory])

    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM projects WHERE github_repo IS NOT NULL
        GROUP BY workspace_id, github_repo HAVING count(*) > 1
      ) THEN
        RAISE EXCEPTION 'há projetos do mesmo workspace com o mesmo github_repo: deixe um só antes de migrar';
      END IF;
    END
    $$;
    """)

    drop_if_exists index(:projects, [:workspace_id, :github_repo])

    create unique_index(:projects, [:workspace_id, :github_repo],
             where: "github_repo IS NOT NULL",
             name: :projects_workspace_id_github_repo_index
           )

    alter table(:jobs) do
      add :project_id, references(:projects, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:jobs, [:project_id])

    flush()
    Enum.each(backfill_jobs_sql(), &execute/1)
  end

  def down do
    alter table(:jobs) do
      remove :project_id
    end

    drop_if_exists index(:projects, [:workspace_id, :github_repo],
                     name: :projects_workspace_id_github_repo_index
                   )

    create index(:projects, [:workspace_id, :github_repo])

    drop_if_exists unique_index(:projects, [:workspace_id, :runner_id, :directory])
    create unique_index(:projects, [:workspace_id, :directory])

    alter table(:projects) do
      remove :runner_id
    end
  end

  @doc "Gives each project without a runner the active runner that offers its directory, seen last."
  def backfill_projects_sql do
    """
    UPDATE projects AS p
    SET runner_id = (
      SELECT r.id FROM runners AS r
      WHERE r.workspace_id = p.workspace_id
        AND r.revoked_at IS NULL
        AND EXISTS (SELECT 1 FROM unnest(r.directories) AS d WHERE d->>'name' = p.directory)
      ORDER BY r.last_seen_at DESC NULLS LAST, r.inserted_at DESC
      LIMIT 1
    )
    WHERE p.runner_id IS NULL
    """
  end

  @doc """
  Gives each job without a project its task's, or else the one project of
  the directory it studied (a proposal) or ran in.
  """
  def backfill_jobs_sql do
    [
      """
      UPDATE jobs AS j
      SET project_id = t.project_id
      FROM stage_runs AS s, tasks AS t
      WHERE j.project_id IS NULL AND s.id = j.stage_run_id AND t.id = s.task_id
        AND t.project_id IS NOT NULL
      """,
      """
      UPDATE jobs AS j
      SET project_id = (
        SELECT min(p.id::text)::uuid FROM projects AS p
        WHERE p.workspace_id = j.workspace_id
          AND p.directory = coalesce(j.context->'proposal'->'input'->>'directory',
                                     j.context->>'directory')
        HAVING count(*) = 1
      )
      WHERE j.project_id IS NULL AND j.stage_run_id IS NULL
      """
    ]
  end
end
