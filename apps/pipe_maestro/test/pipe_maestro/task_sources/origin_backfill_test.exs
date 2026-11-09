defmodule PipeMaestro.TaskSources.OriginBackfillTest do
  use PipeMaestro.DataCase, async: true

  import PipeMaestro.Fixtures

  alias PipeMaestro.{FakeForgejo, Integrations, Repo, Tasks}

  @migration PipeMaestro.Repo.Migrations.AddTaskSource
  @url "https://github.com/acme/app/issues/42"

  setup_all do
    unless Code.ensure_loaded?(@migration) do
      case Path.wildcard(
             Application.app_dir(:pipe_maestro, "priv/repo/migrations/*_add_task_source.exs")
           ) do
        [path] -> Code.require_file(path)
        [] -> :ok
      end
    end

    %{migration: @migration}
  end

  setup do
    workspace = workspace_fixture()
    user = member_fixture(workspace)
    FakeForgejo.start()
    {runner, _token} = runner_fixture(workspace, user)
    runner = with_directories(runner, [%{"name" => "app", "git" => true}])
    project = project_fixture(runner, "app")

    {:ok, repo} =
      Integrations.link_repo(
        connection_fixture(workspace),
        user,
        %{"full_name" => "acme/app", "project_id" => project.id},
        "https://pm.test/hook"
      )

    %{
      workspace: workspace,
      user: user,
      project: project,
      repo: repo,
      pipeline: pipeline_fixture(workspace)
    }
  end

  defp task(ctx) do
    {:ok, task} =
      Tasks.create_task(ctx.user, ctx.workspace, %{
        "title" => "Corrigir o login",
        "prompt" => "O botão não responde",
        "pipeline_id" => ctx.pipeline.id,
        "project_id" => ctx.project.id
      })

    task.id
  end

  # A task as the platform kept it before the sources: only the old columns.
  defp as_before(id, fields) do
    sets =
      fields
      |> Keyword.keys()
      |> Enum.with_index(2)
      |> Enum.map_join(", ", fn {f, i} -> "#{f} = $#{i}" end)

    Repo.query!(
      "UPDATE tasks SET source = NULL, source_id = NULL, source_url = NULL, " <>
        "source_ref = '{}'::jsonb, pending_source_note = NULL, #{sets} WHERE id = $1",
      [Ecto.UUID.dump!(id) | Keyword.values(fields)]
    )
  end

  # The backfill may be one statement or several, in order.
  defp backfill(sql), do: Enum.each(List.wrap(sql), &Repo.query!/1)

  defp origin(id) do
    %{rows: [[source, source_id, source_url, source_ref, note, repo_id]]} =
      Repo.query!(
        "SELECT source, source_id, source_url, source_ref, pending_source_note, linked_repo_id " <>
          "FROM tasks WHERE id = $1",
        [Ecto.UUID.dump!(id)]
      )

    %{
      source: source,
      source_id: source_id,
      source_url: source_url,
      source_ref: source_ref,
      note: note,
      linked_repo_id: repo_id && Ecto.UUID.load!(repo_id)
    }
  end

  test "a task of a linked issue gets its origin, the number and the note kept", ctx do
    sql = ctx.migration.backfill_sql()
    id = task(ctx)

    as_before(id,
      issue_url: @url,
      issue_number: 42,
      linked_repo_id: Ecto.UUID.dump!(ctx.repo.id),
      pending_issue_comment: "**Decisão**: seguir."
    )

    backfill(sql)

    assert origin(id) == %{
             source: "git_issue",
             source_id: @url,
             source_url: @url,
             source_ref: %{"number" => 42},
             note: "**Decisão**: seguir.",
             linked_repo_id: ctx.repo.id
           }
  end

  test "a task made by hand with only the issue's link gets its origin too", ctx do
    sql = ctx.migration.backfill_sql()
    id = task(ctx)
    as_before(id, issue_url: @url)

    backfill(sql)

    assert origin(id) == %{
             source: "git_issue",
             source_id: @url,
             source_url: @url,
             source_ref: %{},
             note: nil,
             linked_repo_id: nil
           }
  end

  test "a task without an issue stays without an origin, and running it twice changes nothing",
       ctx do
    sql = ctx.migration.backfill_sql()
    plain = task(ctx)
    linked = task(ctx)
    as_before(plain, issue_url: nil)
    as_before(linked, issue_url: @url, issue_number: 42)

    backfill(sql)
    first = origin(linked)
    backfill(sql)

    assert origin(plain).source == nil
    assert origin(linked) == first
  end
end
