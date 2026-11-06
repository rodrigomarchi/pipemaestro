defmodule PipeMaestro.Projects.RunnerBackfillTest do
  use PipeMaestro.DataCase, async: true

  import Ecto.Query
  import PipeMaestro.Fixtures

  alias PipeMaestro.Jobs.Job
  alias PipeMaestro.Projects
  alias PipeMaestro.Projects.Project
  alias PipeMaestro.Repo
  alias PipeMaestro.Runners
  alias PipeMaestro.Runners.Runner
  alias PipeMaestro.Tasks

  @migration PipeMaestro.Repo.Migrations.AddRunnerToProjects

  setup_all do
    unless Code.ensure_loaded?(@migration) do
      [path] =
        Path.wildcard(
          Application.app_dir(:pipe_maestro, "priv/repo/migrations/*_add_runner_to_projects.exs")
        )

      Code.require_file(path)
    end

    %{migration: @migration}
  end

  setup do
    workspace = workspace_fixture()
    user = member_fixture(workspace)
    %{workspace: workspace, user: user}
  end

  defp runner(ctx, name, directories, seen_ago) do
    {runner, _token} = runner_fixture(ctx.workspace, ctx.user, %{name: name})
    runner = with_directories(runner, directories)
    seen = DateTime.add(DateTime.utc_now(:second), -seen_ago, :second)
    Repo.update_all(from(r in Runner, where: r.id == ^runner.id), set: [last_seen_at: seen])
    runner
  end

  defp forget_runner(project) do
    Repo.update_all(from(p in Project, where: p.id == ^project.id), set: [runner_id: nil])
  end

  test "each project gets the active runner that offers its directory, seen last", ctx do
    app = [%{"name" => "app", "git" => true}]
    old = runner(ctx, "antigo", app, 3_600)
    recent = runner(ctx, "recente", app, 60)
    revoked = runner(ctx, "revogado", app, 0)
    {:ok, _} = Runners.revoke_runner(revoked)
    _other = runner(ctx, "outro", [%{"name" => "site", "git" => true}], 0)

    project = project_fixture(old, "app")
    forget_runner(project)

    Repo.query!(ctx.migration.backfill_projects_sql())
    assert Repo.get!(Project, project.id).runner_id == recent.id
  end

  test "a project whose directory no runner offers is left without one", ctx do
    runner = runner(ctx, "mac", [%{"name" => "app", "git" => true}], 0)
    project = project_fixture(runner, "app")
    forget_runner(project)
    with_directories(runner, [])

    Repo.query!(ctx.migration.backfill_projects_sql())
    assert Repo.get!(Project, project.id).runner_id == nil
    assert Projects.health(Repo.get!(Project, project.id), MapSet.new()) == :needs_runner
  end

  test "jobs get their task's project, or the one project of the directory they studied",
       ctx do
    runner = runner(ctx, "mac", [%{"name" => "app", "git" => true}], 0)
    project = project_fixture(runner, "app")

    {:ok, task} =
      Tasks.create_task(ctx.user, ctx.workspace, %{
        "title" => "T",
        "prompt" => "p",
        "pipeline_id" => pipeline_fixture(ctx.workspace).id,
        "project_id" => project.id
      })

    [stage_run | _] = task.stage_runs

    proposal =
      Repo.insert!(%Job{
        workspace_id: ctx.workspace.id,
        runner_id: runner.id,
        created_by_user_id: ctx.user.id,
        prompt: "antiga",
        context: %{"proposal" => %{"kind" => "task", "input" => %{"directory" => "app"}}}
      })

    elsewhere =
      Repo.insert!(%Job{
        workspace_id: ctx.workspace.id,
        runner_id: runner.id,
        created_by_user_id: ctx.user.id,
        prompt: "solta",
        context: %{"directory" => "outra"}
      })

    Repo.update_all(from(j in Job, where: j.workspace_id == ^ctx.workspace.id),
      set: [project_id: nil]
    )

    Enum.each(ctx.migration.backfill_jobs_sql(), &Repo.query!/1)

    assert Repo.get!(Job, stage_run.job.id).project_id == project.id
    assert Repo.get!(Job, proposal.id).project_id == project.id
    assert Repo.get!(Job, elsewhere.id).project_id == nil
  end
end
