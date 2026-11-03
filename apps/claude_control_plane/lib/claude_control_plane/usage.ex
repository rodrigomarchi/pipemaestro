defmodule ClaudeControlPlane.Usage do
  @moduledoc """
  What a workspace's agents did in a period, from the jobs that ran and
  ended in it (a job canceled before it started did not run): cost,
  runs and time in total, by day, by pipeline, runner and person, and by
  pipeline stage (with the failed runs, a stage's retries). `tokens` counts
  everything the model read (fresh, from the cache, written to it) and wrote.
  """

  import Ecto.Query

  alias ClaudeControlPlane.Accounts.User
  alias ClaudeControlPlane.Jobs.Job
  alias ClaudeControlPlane.Repo
  alias ClaudeControlPlane.Runners.Runner
  alias ClaudeControlPlane.Tasks.{StageRun, Task}
  alias ClaudeControlPlane.Workspaces.Workspace

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

  @typedoc "The usage report: totals, then the same broken down."
  @type report :: %{
          total: totals(),
          by_day: [map()],
          by_pipeline: [map()],
          by_runner: [map()],
          by_person: [map()],
          by_stage: [map()]
        }

  @doc "The workspace's usage since `since`."
  @spec report(Workspace.t(), DateTime.t()) :: report()
  def report(%Workspace{id: workspace_id}, since) do
    jobs =
      from j in Job,
        where:
          j.workspace_id == ^workspace_id and j.finished_at >= ^since and
            not is_nil(j.started_at)

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
      by_stage: by_stage(jobs)
    }
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
        cost_usd: sum(j.cost_usd),
        runs: count(j.id),
        duration_ms: sum(j.duration_ms),
        tokens: tokens(j)
      }
    )
    |> Repo.all()
    |> Enum.map(&normalize/1)
  end
end
