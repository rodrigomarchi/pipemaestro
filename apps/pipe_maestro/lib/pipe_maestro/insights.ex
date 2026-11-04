defmodule PipeMaestro.Insights do
  @moduledoc """
  How the agent worked, for auditing: consolidates what a job's run reported
  (its events, its OpenTelemetry records and the totals on the job,
  `PipeMaestro.Jobs`) for one job (`job/1`) and for a workspace over a
  period (`workspace/2`). Read only.

  Tool durations, API latencies and errors come from the OpenTelemetry; tool
  calls, permission decisions, retries, compactions and thinking from the
  events; tokens, cost per model and denials from the job.
  """

  import Ecto.Query

  alias PipeMaestro.Jobs.{Event, Job, Telemetry}
  alias PipeMaestro.Repo
  alias PipeMaestro.Workspaces.Workspace

  @typedoc "One tool's use: calls, failed calls, refused calls and time spent."
  @type tool :: %{
          name: String.t(),
          calls: non_neg_integer(),
          errors: non_neg_integer(),
          denied: non_neg_integer(),
          total_ms: non_neg_integer(),
          avg_ms: non_neg_integer() | nil
        }

  @typedoc "One model's share: tokens and cost."
  @type model :: %{
          model: String.t(),
          fresh_input: non_neg_integer(),
          output: non_neg_integer(),
          cache_read: non_neg_integer(),
          cache_creation: non_neg_integer(),
          cost_usd: number()
        }

  @doc """
  One job: its `tools`, `denials`, `api` (requests, latency p50, p95 and max,
  average time to first token, errors, retries), `cache_hit` (the share of
  input read from the cache), `models`, `compactions`, `subagent_calls`,
  `thinking` (how many times and for how long) and the last `rate_limit` seen.
  """
  @spec job(Job.t()) :: %{atom() => term()}
  def job(%Job{} = job) do
    events = Repo.all(from e in Event, where: e.job_id == ^job.id, order_by: e.seq)

    telemetry =
      Repo.all(from t in Telemetry, where: t.job_id == ^job.id, order_by: [asc: t.at, asc: t.id])

    by_type = Enum.group_by(events, & &1.type, & &1.data)
    by_name = Enum.group_by(telemetry, & &1.name, & &1.attrs)

    %{
      tools: job_tools(by_type, by_name),
      denials: denials(job, by_type),
      api: job_api(by_name, by_type),
      cache_hit: Job.cache_hit(job),
      models: models([job.model_usage]),
      compactions: length(by_type["compact"] || []),
      subagent_calls: Enum.count(by_type["tool_use"] || [], & &1["parent_tool_use_id"]),
      thinking: thinking(by_type["thinking"] || []),
      rate_limit: List.last(by_type["rate_limit"] || [])
    }
  end

  defp job_tools(by_type, by_name) do
    results = Map.new(by_type["tool_result"] || [], &{&1["tool_use_id"], &1})
    durations = Map.new(by_name["tool_result"] || [], &{&1["tool_use_id"], &1["duration_ms"]})

    (by_type["tool_use"] || [])
    |> Enum.group_by(& &1["name"])
    |> Enum.map(fn {name, calls} ->
      ids = Enum.map(calls, & &1["id"])
      outcomes = Enum.map(ids, &results[&1])
      measured = ids |> Enum.map(&durations[&1]) |> Enum.filter(&is_number/1)

      %{
        name: name,
        calls: length(calls),
        errors: Enum.count(outcomes, &(&1 && &1["is_error"] == true)),
        denied: Enum.count(outcomes, &(get_in(&1 || %{}, ["decision", "decision"]) == "reject")),
        total_ms: Enum.sum(measured),
        avg_ms: average(measured)
      }
    end)
    |> Enum.sort_by(&{-&1.calls, &1.name})
  end

  # The run's own list when it reported one, else the refusals seen as events.
  defp denials(%Job{permission_denials: [_ | _] = denials}, _by_type), do: denials

  defp denials(_job, by_type),
    do:
      Enum.map(by_type["permission_denied"] || [], &Map.take(&1, ~w(tool_name tool_use_id text)))

  defp job_api(by_name, by_type) do
    requests = by_name["api_request"] || []
    durations = requests |> Enum.map(& &1["duration_ms"]) |> Enum.filter(&is_number/1)

    %{
      requests: length(requests),
      p50_ms: percentile(durations, 50),
      p95_ms: percentile(durations, 95),
      max_ms: Enum.max(durations, fn -> nil end),
      avg_ttft_ms:
        requests |> Enum.map(& &1["ttft_ms"]) |> Enum.filter(&is_number/1) |> average(),
      errors:
        for error <- by_name["api_error"] || [] do
          %{error: error["error"], status: error["status_code"], attempt: error["attempt"]}
        end,
      retries: length(by_type["api_retry"] || [])
    }
  end

  defp thinking(thoughts) do
    %{
      count: length(thoughts),
      total_ms:
        thoughts |> Enum.map(& &1["duration_ms"]) |> Enum.filter(&is_number/1) |> Enum.sum()
    }
  end

  @doc """
  A workspace's jobs that ended in the last `days`: `tokens` (summed, with
  how many jobs), `cache_hit`, `cost_usd`, `models`, `tools` (calls, failed
  calls and average time, from the OpenTelemetry), `api` (requests, errors,
  retries, average latency and time to first token), `denials` and
  `compactions`.
  """
  @spec workspace(Workspace.t(), pos_integer()) :: %{atom() => term()}
  def workspace(%Workspace{id: workspace_id}, days) do
    since = DateTime.add(DateTime.utc_now(), -days, :day)

    jobs =
      from j in Job,
        where: j.workspace_id == ^workspace_id and j.finished_at >= ^since

    tokens =
      Repo.one(
        from j in jobs,
          select: %{
            jobs: count(j.id),
            fresh_input: type(coalesce(sum(j.input_tokens), 0), :integer),
            cache_read: type(coalesce(sum(j.cache_read_tokens), 0), :integer),
            cache_creation: type(coalesce(sum(j.cache_creation_tokens), 0), :integer),
            output: type(coalesce(sum(j.output_tokens), 0), :integer),
            thinking: type(coalesce(sum(j.thinking_tokens), 0), :integer),
            cost_usd: coalesce(sum(j.cost_usd), 0),
            denials:
              type(
                coalesce(sum(fragment("coalesce(cardinality(?), 0)", j.permission_denials)), 0),
                :integer
              )
          }
      )

    job_ids = select(jobs, [j], j.id)

    %{
      tokens: Map.drop(tokens, [:cost_usd, :denials]),
      cost_usd: tokens.cost_usd,
      cache_hit: Job.cache_hit(tokens.fresh_input, tokens.cache_read, tokens.cache_creation),
      models: models(Repo.all(from j in jobs, select: j.model_usage)),
      tools: workspace_tools(job_ids),
      api: workspace_api(job_ids),
      denials: tokens.denials,
      compactions: count_events(job_ids, "compact")
    }
  end

  defp workspace_tools(job_ids) do
    Repo.all(
      from t in Telemetry,
        where: t.job_id in subquery(job_ids) and t.name == "tool_result",
        group_by: fragment("?->>'tool_name'", t.attrs),
        select: %{
          name: fragment("?->>'tool_name'", t.attrs),
          calls: count(t.id),
          errors: sum(fragment("CASE WHEN ?->>'success' = 'false' THEN 1 ELSE 0 END", t.attrs)),
          avg_ms: avg(fragment("(?->>'duration_ms')::numeric", t.attrs))
        }
    )
    |> Enum.map(&%{&1 | avg_ms: round_decimal(&1.avg_ms), errors: &1.errors || 0})
    |> Enum.sort_by(&{-&1.calls, &1.name || ""})
  end

  defp workspace_api(job_ids) do
    requests =
      Repo.one(
        from t in Telemetry,
          where: t.job_id in subquery(job_ids) and t.name == "api_request",
          select: %{
            requests: count(t.id),
            avg_ms: avg(fragment("(?->>'duration_ms')::numeric", t.attrs)),
            avg_ttft_ms: avg(fragment("(?->>'ttft_ms')::numeric", t.attrs))
          }
      )

    errors =
      Repo.aggregate(
        from(t in Telemetry, where: t.job_id in subquery(job_ids) and t.name == "api_error"),
        :count
      )

    %{
      requests: requests.requests,
      avg_ms: round_decimal(requests.avg_ms),
      avg_ttft_ms: round_decimal(requests.avg_ttft_ms),
      errors: errors,
      retries: count_events(job_ids, "api_retry")
    }
  end

  defp count_events(job_ids, type) do
    Repo.aggregate(
      from(e in Event, where: e.job_id in subquery(job_ids) and e.type == ^type),
      :count
    )
  end

  # ── Shared ────────────────────────────────────────────────────────────────

  @spec models([map() | nil]) :: [model()]
  defp models(usages) do
    usages
    |> Enum.flat_map(fn usage -> Map.to_list(usage || %{}) end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.map(fn {model, entries} ->
      %{
        model: model,
        fresh_input: sum_of(entries, "fresh_input"),
        output: sum_of(entries, "output"),
        cache_read: sum_of(entries, "cache_read"),
        cache_creation: sum_of(entries, "cache_creation"),
        cost_usd: sum_of(entries, "cost_usd")
      }
    end)
    |> Enum.sort_by(&{-&1.cost_usd, &1.model})
  end

  defp sum_of(entries, key),
    do: entries |> Enum.map(&(&1[key] || 0)) |> Enum.filter(&is_number/1) |> Enum.sum()

  defp average([]), do: nil
  defp average(values), do: round(Enum.sum(values) / length(values))

  # Nearest rank: the value below which `p`% of the values fall.
  defp percentile([], _p), do: nil

  defp percentile(values, p) do
    sorted = Enum.sort(values)
    Enum.at(sorted, max(ceil(p / 100 * length(sorted)) - 1, 0))
  end

  defp round_decimal(nil), do: nil
  defp round_decimal(%Decimal{} = value), do: value |> Decimal.round(0) |> Decimal.to_integer()
end
