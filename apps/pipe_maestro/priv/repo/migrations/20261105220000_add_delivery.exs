defmodule PipeMaestro.Repo.Migrations.AddDelivery do
  use Ecto.Migration

  def change do
    alter table(:pipelines) do
      # none (the prompt decides), commit (one per stage) or pr (and a draft PR).
      add :delivery, :string, null: false, default: "none"
    end

    alter table(:tasks) do
      add :issue_url, :text
      add :pr_url, :text
      # A decision's summary, commented on the issue with the next stage.
      add :pending_issue_comment, :text
    end

    alter table(:jobs) do
      # What the runner delivered: commit, push, pull request, comment.
      add :delivery, :map
    end
  end
end
