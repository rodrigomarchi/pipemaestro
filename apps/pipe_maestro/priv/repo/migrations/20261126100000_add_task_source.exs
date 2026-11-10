defmodule PipeMaestro.Repo.Migrations.AddTaskSource do
  @moduledoc """
  The origin of a task, whatever its source (ADR 0056): `source` (the key of
  the source, `"git_issue"` for an issue of a git host), `source_id` (the
  item's id there), `source_url`, `source_ref` (what the source keeps of the
  item, the issue's `number`) and `pending_source_note` (a decision's note,
  for the source to deliver).

  Existing tasks with an `issue_url` get the origin `git_issue` from it, its
  `issue_number` and the `pending_issue_comment`. The old columns stay, no
  longer read: the version running while this migrates still reads them.
  """
  use Ecto.Migration

  def up do
    alter table(:tasks) do
      add :source, :text
      add :source_id, :text
      add :source_url, :text
      add :source_ref, :map, default: %{}, null: false
      add :pending_source_note, :text
    end

    create index(:tasks, [:workspace_id, :source, :source_id])

    flush()
    Enum.each(backfill_sql(), &execute/1)
  end

  def down do
    drop index(:tasks, [:workspace_id, :source, :source_id])

    alter table(:tasks) do
      remove :source
      remove :source_id
      remove :source_url
      remove :source_ref
      remove :pending_source_note
    end
  end

  @doc "Fills the origin of the tasks that came from an issue; running it again changes nothing."
  @spec backfill_sql() :: [String.t()]
  def backfill_sql do
    [
      """
      UPDATE tasks
      SET source = 'git_issue',
          source_id = issue_url,
          source_url = issue_url,
          source_ref = CASE WHEN issue_number IS NULL THEN '{}'::jsonb
                            ELSE jsonb_build_object('number', issue_number) END
      WHERE issue_url IS NOT NULL AND source IS NULL
      """,
      """
      UPDATE tasks
      SET pending_source_note = pending_issue_comment
      WHERE pending_issue_comment IS NOT NULL AND pending_source_note IS NULL
      """
    ]
  end
end
