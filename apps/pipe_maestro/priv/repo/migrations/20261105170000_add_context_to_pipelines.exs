defmodule PipeMaestro.Repo.Migrations.AddContextToPipelines do
  use Ecto.Migration

  def change do
    alter table(:pipelines) do
      add :system_prompt, :text
      add :mcp_config, :map
      add :agents, :map
    end

    alter table(:tasks) do
      # The pipeline's system prompt, MCP servers and agents when it started.
      add :pipeline_context, :map
    end
  end
end
