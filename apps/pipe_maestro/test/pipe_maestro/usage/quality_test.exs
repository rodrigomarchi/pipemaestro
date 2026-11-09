defmodule PipeMaestro.Usage.QualityTest do
  use PipeMaestro.DataCase, async: true

  import PipeMaestro.Fixtures

  alias PipeMaestro.{FakeForgejo, Integrations, Repo, Tasks, Usage}
  alias PipeMaestro.Integrations.PrOutcome
  alias PipeMaestro.Tasks.{Decision, StageRun}

  @hour 3_600

  setup do
    FakeForgejo.start()
    workspace = workspace_fixture()
    user = member_fixture(workspace)
    {runner, _token} = runner_fixture(workspace, user, %{name: "mac"})

    runner =
      with_directories(runner, [
        %{"name" => "app", "git" => true},
        %{"name" => "site", "git" => true}
      ])

    app = project_fixture(runner, "app")
    site = project_fixture(runner, "site")

    {:ok, repo} =
      Integrations.link_repo(
        connection_fixture(workspace),
        user,
        %{"full_name" => "acme/app", "project_id" => app.id},
        "https://pm.test/hook"
      )

    ctx = %{
      workspace: workspace,
      user: user,
      repo: repo,
      app: app,
      site: site,
      entrega: pipeline_fixture(workspace, %{"name" => "Entrega"}),
      outra: pipeline_fixture(workspace, %{"name" => "Outra"})
    }

    Map.put(ctx, :since, DateTime.add(DateTime.utc_now(), -7, :day))
  end

  defp task(ctx, pipeline, project \\ nil) do
    {:ok, task} =
      Tasks.create_task(ctx.user, ctx.workspace, %{
        "title" => "T",
        "prompt" => "p",
        "pipeline_id" => pipeline.id,
        "project_id" => (project || ctx.app).id
      })

    task
  end

  defp ago(seconds), do: DateTime.add(DateTime.utc_now(:second), -seconds)

  # The outcome of `task`'s pull request: ready `ready_ago` seconds ago,
  # merged `merge_after` seconds after that when merged.
  defp outcome(ctx, task, state, ready_ago, attrs \\ []) do
    ready_at = ago(ready_ago)
    merge_after = Keyword.get(attrs, :merge_after, 2 * @hour)

    Repo.insert!(
      struct!(PrOutcome,
        task_id: task.id,
        workspace_id: ctx.workspace.id,
        linked_repo_id: ctx.repo.id,
        pr_number: :erlang.phash2(task.id, 10_000) + 1,
        pr_url: "https://forge.test/acme/app/pulls/#{task.id}",
        ready_at: ready_at,
        state: state,
        merged_at: if(state == "merged", do: DateTime.add(ready_at, merge_after)),
        closed_at: if(state != "open", do: DateTime.add(ready_at, merge_after)),
        review_rounds: Keyword.get(attrs, :review_rounds, 0),
        human_shas: Keyword.get(attrs, :human_shas, []),
        pipeline_shas: ["p1"],
        commits_tracked: Keyword.get(attrs, :commits_tracked, true),
        commits_final: state != "open"
      )
    )
  end

  defp run(task, index, key, attempt, requeue \\ 0) do
    Repo.insert!(%StageRun{
      task_id: task.id,
      index: index,
      key: key,
      name: key,
      attempt: attempt,
      requeue: requeue,
      status: :failed
    })
  end

  defp decision(task, index, action, attrs \\ []) do
    Repo.insert!(
      struct!(Decision,
        task_id: task.id,
        stage_index: index,
        action: action,
        origin: attrs[:origin],
        inserted_at: Keyword.get(attrs, :at, DateTime.utc_now())
      )
    )
  end

  # A correction stage added at the end of the task (index 2), asked from `origin`.
  defp correction(task, origin) do
    run(task, 2, "correcao-1", 1)
    decision(task, 2, :correct, origin: origin)
  end

  # Five pull requests of "Entrega" in the period (one of each outcome, two
  # accepted with changes), one of "Outra" in another project, and one of
  # "Entrega" from before the period.
  defp scenario(ctx) do
    clean = task(ctx, ctx.entrega)
    human = task(ctx, ctx.entrega)
    reviewed = task(ctx, ctx.entrega)
    closed = task(ctx, ctx.entrega)
    open = task(ctx, ctx.entrega)
    other = task(ctx, ctx.outra, ctx.site)
    old = task(ctx, ctx.entrega)

    outcome(ctx, clean, "merged", 2 * 86_400, merge_after: 2 * @hour)
    outcome(ctx, human, "merged", 86_400, merge_after: 4 * @hour, human_shas: ["h1"])
    outcome(ctx, reviewed, "merged", 86_400, merge_after: 6 * @hour, review_rounds: 1)
    outcome(ctx, closed, "closed", 86_400)
    outcome(ctx, open, "open", @hour, commits_tracked: false)
    outcome(ctx, other, "merged", 3 * 86_400, merge_after: 8 * @hour)
    outcome(ctx, old, "merged", 40 * 86_400)

    # Stage a of `clean`: two more attempts, the last one lost once and run
    # again; two decisions to redo it (and one from before the period).
    run(clean, 0, "a", 2)
    run(clean, 0, "a", 3)
    run(clean, 0, "a", 3, 1)
    decision(clean, 0, :retry)
    decision(clean, 0, :retry)
    decision(clean, 0, :retry, at: DateTime.add(DateTime.utc_now(), -40, :day))

    # Stage b: moved on once, canceled once, and a task waiting there now.
    run(clean, 1, "b", 1)
    run(closed, 1, "b", 1)
    run(open, 1, "b", 1)
    decision(clean, 1, :advance)
    decision(closed, 1, :cancel)

    open
    |> Ecto.Changeset.change(status: :awaiting_decision, current_stage: 1, decision_reason: "?")
    |> Repo.update!()

    # Corrections: one from a review, one from the automatic merge, one a
    # person asked for.
    correction(reviewed, :review)
    correction(clean, :auto_merge)
    correction(human, :person)

    %{clean: clean, human: human, other: other}
  end

  test "the rates of the pull requests delivered, in total and by pipeline", ctx do
    scenario(ctx)
    quality = Usage.quality(ctx.workspace, ctx.since)

    assert %{
             delivered: 6,
             accepted_clean: 2,
             accepted_changed: 2,
             closed: 1,
             open: 1,
             untracked: 1
           } = quality.total

    assert_in_delta quality.total.clean_pct, 33.3, 0.1
    assert_in_delta quality.total.changed_pct, 33.3, 0.1
    assert_in_delta quality.total.closed_pct, 16.7, 0.1
    # Merged after 2, 4, 6 and 8 hours.
    assert quality.total.median_merge_ms == 5 * @hour * 1_000
    assert_in_delta quality.total.review_rounds_per_pr, 1 / 6, 0.01

    entrega = Enum.find(quality.by_pipeline, &(&1.name == "Entrega"))

    assert %{delivered: 5, accepted_clean: 1, accepted_changed: 2, closed: 1, open: 1} = entrega
    assert entrega.clean_pct == 20.0
    assert entrega.median_merge_ms == 4 * @hour * 1_000
    assert_in_delta entrega.review_rounds_per_pr, 0.2, 0.001

    assert %{delivered: 1, accepted_clean: 1} =
             Enum.find(quality.by_pipeline, &(&1.name == "Outra"))
  end

  test "rework by stage matches the stage runs and decisions of the period", ctx do
    scenario(ctx)
    quality = Usage.quality(ctx.workspace, ctx.since)

    stage = fn key ->
      Enum.find(quality.by_stage, &(&1.pipeline == "Entrega" and &1.stage == key))
    end

    # Two attempts past the first (a lost run is no attempt); redone by two
    # decisions and one requeue; two decisions and two pauses.
    assert %{retries: 2, redone: 3, decisions: 2, pauses: 2} = stage.("a")
    assert %{retries: 0, redone: 0, decisions: 2, pauses: 3} = stage.("b")

    assert %{name: "Correções", review_fixes: 1, merge_fixes: 1, person_fixes: 1} =
             stage.("correcao")

    assert [%{stage: "b", pauses: 3}, %{stage: "a", pauses: 2} | _] = quality.top_pauses
  end

  test "the rate of accepted without changes by week", ctx do
    scenario(ctx)
    weeks = Usage.quality(ctx.workspace, ctx.since).by_week

    assert Enum.all?(weeks, &(Date.day_of_week(&1.week) == 1))
    assert Enum.sum(Enum.map(weeks, & &1.delivered)) == 6
    assert Enum.sum(Enum.map(weeks, & &1.accepted_clean)) == 2
    assert Enum.all?(weeks, &(&1.clean_pct == &1.accepted_clean / &1.delivered * 100))
  end

  test "filters by pipeline, project and period", ctx do
    scenario(ctx)

    assert Usage.quality(ctx.workspace, ctx.since, %{"pipeline" => "Outra"}).total.delivered == 1

    by_project = Usage.quality(ctx.workspace, ctx.since, %{"project_id" => ctx.site.id})
    assert by_project.total.delivered == 1
    assert [%{name: "Outra"}] = by_project.by_pipeline

    assert Usage.quality(ctx.workspace, ctx.since, %{"project_id" => "nada"}).total.delivered == 0

    ninety = Usage.quality(ctx.workspace, DateTime.add(DateTime.utc_now(), -90, :day))
    assert ninety.total.delivered == 7
    assert %{retries: 2, redone: 4} = Enum.find(ninety.by_stage, &(&1.stage == "a"))

    only_outra = Usage.quality(ctx.workspace, ctx.since, %{"pipeline" => "Outra"})
    refute Enum.any?(only_outra.by_stage, &(&1.pipeline == "Entrega"))
  end

  test "nothing delivered in the period", ctx do
    quality = Usage.quality(ctx.workspace, ctx.since)

    assert %{delivered: 0, clean_pct: +0.0, median_merge_ms: nil, review_rounds_per_pr: +0.0} =
             quality.total

    assert quality.by_pipeline == []
    assert quality.by_week == []
    assert quality.top_pauses == []
  end
end
