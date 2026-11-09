defmodule PipeMaestro.Usage do
  @moduledoc """
  What a workspace's agents did in a period, from the jobs that ran and
  ended in it (a job canceled before it started did not run): cost,
  runs and time in total, by day, by pipeline, project, runner and person,
  and by
  pipeline stage (with the failed runs, a stage's retries, and the average
  time a run waited for its runner and spent in the stage's gates), and by
  origin: a pipeline's stages, each kind of proposal
  (`PipeMaestro.Proposals`) and the jobs sent on their own. `tokens` counts
  everything the model read (fresh, from the cache, written to it) and wrote.
  """

  import Ecto.Query

  alias PipeMaestro.Accounts.User
  alias PipeMaestro.Insights
  alias PipeMaestro.Integrations.PrOutcome
  alias PipeMaestro.Projects.Project
  alias PipeMaestro.Repo
  alias PipeMaestro.Runners.Runner
  alias PipeMaestro.Tasks.{Decision, StageRun, Task}
  alias PipeMaestro.Workspaces.Workspace

  @typedoc "Cost, runs, time and tokens of a group of jobs."
  @type totals :: %{
          cost_usd: Decimal.t(),
          runs: non_neg_integer(),
          duration_ms: non_neg_integer(),
          tokens: non_neg_integer()
        }

  # The tokens a group of jobs read and wrote, in a query's select.
  defmacrop tokens(job) do
    quote do
      type(
        coalesce(
          sum(
            fragment(
              "coalesce(?, 0) + coalesce(?, 0) + coalesce(?, 0) + coalesce(?, 0)",
              unquote(job).input_tokens,
              unquote(job).cache_read_tokens,
              unquote(job).cache_creation_tokens,
              unquote(job).output_tokens
            )
          ),
          0
        ),
        :integer
      )
    end
  end

  # Where a job came from: a pipeline's stage, a proposal of a kind, or sent
  # on its own.
  defmacrop origin(job) do
    quote do
      fragment(
        "CASE WHEN ? IS NOT NULL THEN 'stage' WHEN ?->'proposal'->>'kind' IS NOT NULL THEN 'proposal:' || (?->'proposal'->>'kind') ELSE 'standalone' END",
        unquote(job).stage_run_id,
        unquote(job).context,
        unquote(job).context
      )
    end
  end

  @typedoc "The usage report: totals, then the same broken down."
  @type report :: %{
          total: totals(),
          by_day: [map()],
          by_pipeline: [map()],
          by_project: [map()],
          by_runner: [map()],
          by_person: [map()],
          by_stage: [map()],
          by_origin: [map()]
        }

  @doc """
  The workspace's usage since `since`, optionally only a `"pipeline"`'s (its
  name, in `filters`) or a project's (`"project_id"`). `by_project` names
  the jobs of no project (from before projects, or of a project deleted
  since) `"sem projeto"`. `by_origin` names each origin `"stage"`,
  `"standalone"` or `"proposal:<kind>"`.
  """
  @spec report(Workspace.t(), DateTime.t(), map()) :: report()
  def report(%Workspace{} = workspace, since, filters \\ %{}) do
    jobs =
      from j in Insights.jobs_query(workspace, since, filters),
        where: not is_nil(j.started_at)

    %{
      total:
        jobs
        |> select([j], %{
          cost_usd: sum(j.cost_usd),
          runs: count(j.id),
          duration_ms: sum(j.duration_ms),
          tokens: tokens(j)
        })
        |> Repo.one()
        |> normalize(),
      by_day: by_day(jobs),
      by_pipeline: by_pipeline(jobs),
      by_project: by_project(jobs),
      by_runner: by_runner(jobs),
      by_person: by_person(jobs),
      by_stage: by_stage(jobs),
      by_origin: by_origin(jobs)
    }
  end

  @doc "The names of the pipelines the workspace's tasks ran, sorted."
  @spec pipeline_names(Workspace.t()) :: [String.t()]
  def pipeline_names(%Workspace{id: workspace_id}) do
    Repo.all(
      from t in Task,
        where: t.workspace_id == ^workspace_id and not is_nil(t.pipeline_name),
        distinct: true,
        order_by: t.pipeline_name,
        select: t.pipeline_name
    )
  end

  defp normalize(row) do
    row
    |> Map.update(:cost_usd, Decimal.new(0), &(&1 || Decimal.new(0)))
    |> Map.update(:duration_ms, 0, &(&1 || 0))
  end

  defp by_day(jobs) do
    from(j in jobs,
      group_by: fragment("date(?)", j.finished_at),
      order_by: fragment("date(?)", j.finished_at),
      select: %{
        date: fragment("date(?)", j.finished_at),
        cost_usd: sum(j.cost_usd),
        runs: count(j.id),
        duration_ms: sum(j.duration_ms),
        tokens: tokens(j)
      }
    )
    |> Repo.all()
    |> Enum.map(&normalize/1)
  end

  defp by_pipeline(jobs) do
    from(j in jobs,
      join: r in StageRun,
      on: r.id == j.stage_run_id,
      join: t in Task,
      on: t.id == r.task_id,
      group_by: t.pipeline_name,
      order_by: [desc: sum(j.cost_usd)],
      select: %{
        name: t.pipeline_name,
        tasks: count(t.id, :distinct),
        cost_usd: sum(j.cost_usd),
        runs: count(j.id),
        duration_ms: sum(j.duration_ms),
        tokens: tokens(j)
      }
    )
    |> Repo.all()
    |> Enum.map(&normalize/1)
  end

  defp by_project(jobs) do
    from(j in jobs,
      left_join: p in Project,
      on: p.id == j.project_id,
      group_by: [p.id, p.name],
      order_by: [desc: sum(j.cost_usd), asc: p.name],
      select: %{
        project_id: p.id,
        name: coalesce(p.name, "sem projeto"),
        cost_usd: sum(j.cost_usd),
        runs: count(j.id),
        duration_ms: sum(j.duration_ms),
        tokens: tokens(j)
      }
    )
    |> Repo.all()
    |> Enum.map(&normalize/1)
  end

  defp by_runner(jobs) do
    from(j in jobs,
      join: r in Runner,
      on: r.id == j.runner_id,
      group_by: r.name,
      order_by: [desc: sum(j.cost_usd)],
      select: %{
        name: r.name,
        cost_usd: sum(j.cost_usd),
        runs: count(j.id),
        duration_ms: sum(j.duration_ms),
        tokens: tokens(j)
      }
    )
    |> Repo.all()
    |> Enum.map(&normalize/1)
  end

  defp by_person(jobs) do
    from(j in jobs,
      join: u in User,
      on: u.id == j.created_by_user_id,
      group_by: u.name,
      order_by: [desc: sum(j.cost_usd)],
      select: %{
        name: u.name,
        cost_usd: sum(j.cost_usd),
        runs: count(j.id),
        duration_ms: sum(j.duration_ms),
        tokens: tokens(j)
      }
    )
    |> Repo.all()
    |> Enum.map(&normalize/1)
  end

  defp by_stage(jobs) do
    from(j in jobs,
      join: r in StageRun,
      on: r.id == j.stage_run_id,
      join: t in Task,
      on: t.id == r.task_id,
      group_by: [t.pipeline_name, r.key, r.name],
      order_by: [t.pipeline_name, min(r.index)],
      select: %{
        pipeline: t.pipeline_name,
        stage: r.key,
        name: r.name,
        failed: filter(count(j.id), j.status == :failed),
        avg_queue_ms: avg(fragment("(?->'timing'->>'queue')::numeric", j.insights)),
        avg_gates_ms: avg(fragment("(?->'timing'->>'gates')::numeric", j.insights)),
        cost_usd: sum(j.cost_usd),
        runs: count(j.id),
        duration_ms: sum(j.duration_ms),
        tokens: tokens(j)
      }
    )
    |> Repo.all()
    |> Enum.map(fn row ->
      row
      |> normalize()
      |> Map.update!(:avg_queue_ms, &round_decimal/1)
      |> Map.update!(:avg_gates_ms, &round_decimal/1)
    end)
  end

  defp by_origin(jobs) do
    from(j in jobs,
      group_by: origin(j),
      order_by: [desc: sum(j.cost_usd)],
      select: %{
        origin: origin(j),
        cost_usd: sum(j.cost_usd),
        runs: count(j.id),
        duration_ms: sum(j.duration_ms),
        tokens: tokens(j)
      }
    )
    |> Repo.all()
    |> Enum.map(&normalize/1)
  end

  defp round_decimal(nil), do: nil
  defp round_decimal(%Decimal{} = value), do: value |> Decimal.round(0) |> Decimal.to_integer()

  # ── Quality ───────────────────────────────────────────────────────────────

  @typedoc """
  How a group of delivered pull requests was accepted: how many, each
  outcome and its share of them (0 to 100), those whose commits the platform
  could not read, the median time from ready to merged and the review rounds
  per pull request.
  """
  @type acceptance :: %{
          delivered: non_neg_integer(),
          accepted_clean: non_neg_integer(),
          accepted_changed: non_neg_integer(),
          closed: non_neg_integer(),
          open: non_neg_integer(),
          untracked: non_neg_integer(),
          clean_pct: float(),
          changed_pct: float(),
          closed_pct: float(),
          median_merge_ms: non_neg_integer() | nil,
          review_rounds_per_pr: float()
        }

  @typedoc "The rework of a pipeline's stage in a period."
  @type stage_rework :: %{
          pipeline: String.t() | nil,
          stage: String.t(),
          name: String.t(),
          retries: non_neg_integer(),
          redone: non_neg_integer(),
          decisions: non_neg_integer(),
          pauses: non_neg_integer(),
          review_fixes: non_neg_integer(),
          merge_fixes: non_neg_integer(),
          person_fixes: non_neg_integer()
        }

  @typedoc "The quality report: acceptance in total, by pipeline and by week, and rework by stage."
  @type quality :: %{
          total: acceptance(),
          by_pipeline: [map()],
          by_week: [map()],
          by_stage: [stage_rework()],
          top_pauses: [stage_rework()]
        }

  @top_pauses 10

  # The key of a stage, with every correction ("correcao-N") as one.
  defmacrop stage_key(key) do
    quote do
      fragment(
        "CASE WHEN ? LIKE 'correcao-%' THEN 'correcao' ELSE ? END",
        unquote(key),
        unquote(key)
      )
    end
  end

  # How a group of outcomes was accepted, in a query's select.
  defmacrop acceptance(o) do
    quote do
      %{
        delivered: count(unquote(o).id),
        accepted_clean:
          filter(
            count(unquote(o).id),
            unquote(o).state == "merged" and
              fragment("cardinality(?) = 0", unquote(o).human_shas) and
              unquote(o).review_rounds == 0
          ),
        merged: filter(count(unquote(o).id), unquote(o).state == "merged"),
        closed: filter(count(unquote(o).id), unquote(o).state == "closed"),
        open: filter(count(unquote(o).id), unquote(o).state == "open"),
        untracked: filter(count(unquote(o).id), not unquote(o).commits_tracked),
        review_rounds: coalesce(sum(unquote(o).review_rounds), 0),
        median_merge_s:
          fragment(
            "percentile_cont(0.5) WITHIN GROUP (ORDER BY extract(epoch FROM ? - ?)) FILTER (WHERE ? = 'merged')",
            unquote(o).merged_at,
            unquote(o).ready_at,
            unquote(o).state
          )
      }
    end
  end

  @doc """
  The quality of what the workspace's tasks delivered, with the filters of
  `report/3`:

  - the pull requests that became ready since `since`
    (`PipeMaestro.Integrations.PrOutcome`), in total, by pipeline and by
    week (a Monday): accepted without changes (merged as the pipeline left
    it), with changes (a person's commit or a correction a review asked
    for), closed without the merge, or still open;
  - the stages' rework in the period (`by_stage`, by pipeline and stage key,
    every "Correção N" as `"correcao"`): attempts past the first
    (`retries`, a lost run is none), runs again (`redone`: decisions to
    retry and runs lost and run again), decisions taken (`decisions`, no
    corrections), pauses for a decision (`pauses`: the decisions that ended
    one and the tasks waiting there now), and corrections by who asked
    (`review_fixes`, `merge_fixes`, `person_fixes`);
  - the stages that stop the most for a decision (`top_pauses`).
  """
  @spec quality(Workspace.t(), DateTime.t(), map()) :: quality()
  def quality(%Workspace{id: workspace_id}, since, filters \\ %{}) do
    tasks = filtered_tasks(workspace_id, filters)

    outcomes =
      from o in PrOutcome,
        join: t in subquery(tasks),
        on: t.id == o.task_id,
        where: o.ready_at >= ^since

    by_stage = rework(tasks, since)

    %{
      total: outcomes |> select([o], acceptance(o)) |> Repo.one() |> acceptance_row(),
      by_pipeline:
        from([o, t] in outcomes,
          group_by: t.pipeline_name,
          order_by: [desc: count(o.id), asc: t.pipeline_name],
          select: {t.pipeline_name, acceptance(o)}
        )
        |> Repo.all()
        |> Enum.map(fn {name, row} -> Map.put(acceptance_row(row), :name, name) end),
      by_week:
        from([o] in outcomes,
          group_by: fragment("date_trunc('week', ?)::date", o.ready_at),
          order_by: fragment("date_trunc('week', ?)::date", o.ready_at),
          select: {fragment("date_trunc('week', ?)::date", o.ready_at), acceptance(o)}
        )
        |> Repo.all()
        |> Enum.map(fn {week, row} ->
          row = acceptance_row(row)

          %{
            week: week,
            delivered: row.delivered,
            accepted_clean: row.accepted_clean,
            clean_pct: row.clean_pct
          }
        end),
      by_stage: by_stage,
      top_pauses:
        by_stage
        |> Enum.filter(&(&1.pauses > 0))
        |> Enum.sort_by(& &1.pauses, :desc)
        |> Enum.take(@top_pauses)
    }
  end

  defp filtered_tasks(workspace_id, filters) do
    query = from(t in Task, where: t.workspace_id == ^workspace_id)

    query =
      case filters["pipeline"] do
        name when is_binary(name) and name != "" -> where(query, [t], t.pipeline_name == ^name)
        _all -> query
      end

    case filters["project_id"] do
      id when is_binary(id) and id != "" ->
        case Ecto.UUID.cast(id) do
          {:ok, id} -> where(query, [t], t.project_id == ^id)
          :error -> where(query, false)
        end

      _all ->
        query
    end
  end

  defp acceptance_row(row) do
    delivered = row.delivered
    changed = row.merged - row.accepted_clean

    %{
      delivered: delivered,
      accepted_clean: row.accepted_clean,
      accepted_changed: changed,
      closed: row.closed,
      open: row.open,
      untracked: row.untracked,
      clean_pct: pct(row.accepted_clean, delivered),
      changed_pct: pct(changed, delivered),
      closed_pct: pct(row.closed, delivered),
      median_merge_ms: row.median_merge_s && round(row.median_merge_s * 1_000),
      review_rounds_per_pr: if(delivered == 0, do: 0.0, else: row.review_rounds / delivered)
    }
  end

  defp pct(_count, 0), do: 0.0
  defp pct(count, total), do: count / total * 100

  # The stage key of each run's (task, index), for decisions and pauses,
  # which keep only the index.
  defp stage_keys do
    from r in StageRun,
      distinct: [r.task_id, r.index],
      select: %{task_id: r.task_id, index: r.index, key: r.key, name: r.name}
  end

  defp rework(tasks, since) do
    runs =
      from(r in StageRun,
        join: t in subquery(tasks),
        on: t.id == r.task_id,
        where: r.inserted_at >= ^since,
        group_by: [t.pipeline_name, stage_key(r.key)],
        select:
          {{t.pipeline_name, stage_key(r.key)},
           %{
             order: min(r.index),
             name: max(r.name),
             retries: filter(count(r.id), r.attempt > 1 and r.requeue == 0),
             requeues: type(coalesce(sum(r.requeue), 0), :integer)
           }}
      )
      |> Repo.all()

    decisions =
      from(d in Decision,
        join: t in subquery(tasks),
        on: t.id == d.task_id,
        join: k in subquery(stage_keys()),
        on: k.task_id == d.task_id and k.index == d.stage_index,
        where: d.inserted_at >= ^since,
        group_by: [t.pipeline_name, stage_key(k.key)],
        select:
          {{t.pipeline_name, stage_key(k.key)},
           %{
             order: min(d.stage_index),
             name: max(k.name),
             retried: filter(count(d.id), d.action == :retry),
             decisions: filter(count(d.id), d.action != :correct),
             review_fixes: filter(count(d.id), d.action == :correct and d.origin == :review),
             merge_fixes: filter(count(d.id), d.action == :correct and d.origin == :auto_merge),
             person_fixes:
               filter(
                 count(d.id),
                 d.action == :correct and (d.origin == :person or is_nil(d.origin))
               )
           }}
      )
      |> Repo.all()

    waiting =
      from(t in subquery(tasks),
        join: k in subquery(stage_keys()),
        on: k.task_id == t.id and k.index == t.current_stage,
        where: t.status == :awaiting_decision,
        group_by: [t.pipeline_name, stage_key(k.key)],
        select:
          {{t.pipeline_name, stage_key(k.key)},
           %{order: min(t.current_stage), name: max(k.name), waiting: count(t.id)}}
      )
      |> Repo.all()

    (runs ++ decisions ++ waiting)
    |> Enum.group_by(fn {group, _row} -> group end, fn {_group, row} -> row end)
    |> Enum.map(fn {{pipeline, stage}, rows} -> stage_rework(pipeline, stage, rows) end)
    |> Enum.sort_by(&{&1.pipeline || "", &1.order})
    |> Enum.map(&Map.delete(&1, :order))
  end

  defp stage_rework(pipeline, stage, rows) do
    total = fn key -> rows |> Enum.map(&Map.get(&1, key, 0)) |> Enum.sum() end
    decisions = total.(:decisions)

    %{
      pipeline: pipeline,
      stage: stage,
      name:
        if(stage == "correcao",
          do: "Correções",
          else: Enum.find_value(rows, stage, & &1.name)
        ),
      order:
        if(stage == "correcao", do: :infinity, else: rows |> Enum.map(& &1.order) |> Enum.min()),
      retries: total.(:retries),
      redone: total.(:retried) + total.(:requeues),
      decisions: decisions,
      pauses: decisions + total.(:waiting),
      review_fixes: total.(:review_fixes),
      merge_fixes: total.(:merge_fixes),
      person_fixes: total.(:person_fixes)
    }
  end
end
