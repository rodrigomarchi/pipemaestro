defmodule PipeMaestro.Repo.Migrations.AddStatusCommentToIntegrationIssues do
  use Ecto.Migration

  def change do
    # The platform's status comment on the issue, written when the issue is
    # taken and kept by the task that comes of it.
    alter table(:integration_issues) do
      add :status_comment_id, :string
    end
  end
end
