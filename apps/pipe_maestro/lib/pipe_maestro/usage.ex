defmodule PipeMaestro.Usage do
  @moduledoc """
  What a workspace's agents did in a period, from the jobs that ran and
  ended in it (a job canceled before it started did not run): cost,
  runs and time in total, by day, by pipeline, runner and person, and by
  pipeline stage (with the failed runs, a stage's retries, and the average
  time a run waited for its runner and spent in the stage's gates), and by
  origin: a pipeline's stages, each kind of proposal
  (`PipeMaestro.Proposals`) and the jobs sent on their own. `tokens` counts
  everything the model read (fresh, from the cache, written to it) and wrote.
  """

  import Ecto.Query

  alias PipeMaestro.Accounts.User
  alias PipeMaestro.Insights
  alias PipeMaestro.Repo
  alias PipeMaestro.Runners.Runner
  alias PipeMaestro.Tasks.{StageRun, Task}
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
          by_runner: [map()],
          by_person: [map()],
          by_stage: [map()],
          by_origin: [map()]
        }

  @doc """
  The workspace's usage since `since`, optionally only a `"pipeline"`'s (its
  name, in `filters`). `by_origin` names each origin `"stage"`,
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
end
