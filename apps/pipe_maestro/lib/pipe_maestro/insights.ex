defmodule PipeMaestro.Insights do
  @moduledoc """
  How the agent worked, for auditing: consolidates what a job's run reported
  (its events, its OpenTelemetry records and the totals on the job,
  `PipeMaestro.Jobs`) for one job (`job/1`), for a running job so far
  (`live/1`) and for a workspace over a period (`workspace/3`).

  Tool durations, API latencies, errors and refusals, MCP connections,
  permission decisions and subagents come from the OpenTelemetry; tool calls,
  retries, compactions and thinking from the events; tokens, cost per model,
  denials and the time the run took from the job.

  Once a run ends, its summary (`summarize/1`) is kept on the job (`insights`)
  and its tools in `PipeMaestro.Jobs.ToolStat` (`store_summary/1`): the
  events and records it comes from are removed after a while
  (`PipeMaestro.Maintenance`), the summary stays, and the workspace's view
  adds summaries up, over any period.
  """

  import Ecto.Query

  alias PipeMaestro.Jobs.{Event, Job, Telemetry, ToolStat}
  alias PipeMaestro.Repo
  alias PipeMaestro.Tasks.{StageRun, Task}
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

  @typedoc """
  A run's summary, as kept on the job (string keys, as JSON):

    * `"api"` — `requests`, latency `p50_ms`, `p95_ms`, `max_ms`,
      `avg_ttft_ms`, the sums and counts behind the averages (`ms_sum`,
      `ms_count`, `ttft_sum`, `ttft_count`), `errors` (each `error`, `status`,
      `attempt`), `error_count`, `refusals` and `retries`;
    * `"denials"`, `"compactions"`, `"subagent_calls"`, `"thinking"` (`count`,
      `total_ms`) and the last `"rate_limit"` seen;
    * `"timing"` — where the time went, in ms: `queue` (waiting for the
      runner), `setup`, `gates`, `api`, `tools` (summed: tools may run at
      once) and `wall`;
    * `"extras"` — `active_seconds`, `mcp` (each connection: `transport`,
      `scope`, `status`, `duration_ms`), `mcp_failures`, `decisions` (by
      `source` and `decision`), `subagents` (by `agent_type`) and
      `by_query_source` (`requests` and `cost_usd` by the API call's origin).
  """
  @type summary :: %{String.t() => term()}

  @doc """
  One job: its `tools`, `denials`, `api` (requests, latency p50, p95 and max,
  average time to first token, errors, refusals, retries), `cache_hit` (the
  share of input read from the cache), `models`, `compactions`,
  `subagent_calls`, `thinking` (how many times and for how long), the last
  `rate_limit` seen, `timing` and `extras` (see `t:summary/0`). A job that
  ended reads its kept summary; one without, from its events and records.
  """
  @spec job(Job.t()) :: %{atom() => term()}
  def job(%Job{insights: %{} = summary} = job) do
    tools =
      Repo.all(
        from s in ToolStat,
          where: s.job_id == ^job.id,
          select: %{
            name: s.name,
            calls: s.calls,
            errors: s.errors,
            denied: s.denied,
            total_ms: s.total_ms,
            measured: s.measured
          }
      )

    view(job, summary, tools)
  end

  def job(%Job{} = job) do
    {summary, tools} = summarize(job)
    view(job, summary, tools)
  end

  @doc """
  A job's summary from its events, records and columns, with its tools
  (`calls`, `errors`, `denied`, `total_ms`, `measured`), most called first.
  """
  @spec summarize(Job.t()) :: {summary(), [map()]}
  def summarize(%Job{} = job) do
    events = Repo.all(from e in Event, where: e.job_id == ^job.id, order_by: e.seq)

    telemetry =
      Repo.all(from t in Telemetry, where: t.job_id == ^job.id, order_by: [asc: t.at, asc: t.id])

    by_type = Enum.group_by(events, & &1.type, & &1.data)
    by_name = Enum.group_by(telemetry, & &1.name, & &1.attrs)
    tools = job_tools(by_type, by_name)

    summary = %{
      "api" => job_api(by_name, by_type),
      "denials" => denials(job, by_type),
      "compactions" => length(by_type["compact"] || []),
      "subagent_calls" => Enum.count(by_type["tool_use"] || [], & &1["parent_tool_use_id"]),
      "thinking" => thinking(by_type["thinking"] || []),
      "rate_limit" => List.last(by_type["rate_limit"] || []),
      "timing" => timing(job, tools),
      "extras" => extras(job, by_name)
    }

    {summary, tools}
  end

  @doc """
  Keeps the job's summary (`summarize/1`) on it and its tools as
  `PipeMaestro.Jobs.ToolStat`, replacing what was kept before. A job whose
  events the retention pruned keeps the summary it has: what is left of its
  events would not make the same one.
  """
  @spec store_summary(Job.t()) :: :ok
  def store_summary(%Job{events_pruned_at: %DateTime{}}), do: :ok

  def store_summary(%Job{} = job) do
    {summary, tools} = summarize(job)

    rows =
      for tool <- tools do
        Map.merge(tool, %{
          id: Ecto.UUID.generate(),
          job_id: job.id,
          workspace_id: job.workspace_id
        })
      end

    {:ok, _} =
      Repo.transaction(fn ->
        Repo.update_all(from(j in Job, where: j.id == ^job.id), set: [insights: summary])
        Repo.delete_all(from s in ToolStat, where: s.job_id == ^job.id)
        Repo.insert_all(ToolStat, rows)
      end)

    :ok
  end

  @doc """
  A running job so far, from its records and events: `cost_usd`, `tokens`
  (everything the model read and wrote), `requests` to the model and
  `tool_calls`.
  """
  @spec live(Job.t()) :: %{atom() => number()}
  def live(%Job{id: job_id}) do
    api =
      Repo.one(
        from t in Telemetry,
          where: t.job_id == ^job_id and t.name == "api_request",
          select: %{
            requests: count(t.id),
            cost_usd: sum(fragment("coalesce((?->>'cost_usd')::numeric, 0)", t.attrs)),
            tokens:
              sum(
                fragment(
                  "coalesce((?->>'input_tokens')::bigint, 0) + coalesce((?->>'output_tokens')::bigint, 0) + coalesce((?->>'cache_read_tokens')::bigint, 0) + coalesce((?->>'cache_creation_tokens')::bigint, 0)",
                  t.attrs,
                  t.attrs,
                  t.attrs,
                  t.attrs
                )
              )
          }
      )

    tool_calls =
      Repo.aggregate(
        from(e in Event, where: e.job_id == ^job_id and e.type == "tool_use"),
        :count
      )

    %{
      requests: api.requests,
      cost_usd: if(api.cost_usd, do: Decimal.to_float(api.cost_usd), else: 0),
      tokens: decimal_integer(api.tokens) || 0,
      tool_calls: tool_calls
    }
  end

  # ── One job ───────────────────────────────────────────────────────────────

  defp view(job, summary, tools) do
    %{
      tools: tools |> Enum.map(&tool_view/1) |> Enum.sort_by(&{-&1.calls, &1.name}),
      denials: Map.get(summary, "denials") || [],
      api: api_view(Map.get(summary, "api") || %{}),
      cache_hit: Job.cache_hit(job),
      models: models([job.model_usage]),
      compactions: Map.get(summary, "compactions") || 0,
      subagent_calls: Map.get(summary, "subagent_calls") || 0,
      thinking: zeroed(pick(Map.get(summary, "thinking") || %{}, [:count, :total_ms])),
      rate_limit: summary["rate_limit"],
      timing: timing_view(Map.get(summary, "timing") || %{}),
      extras: extras_view(Map.get(summary, "extras") || %{})
    }
  end

  defp api_view(api) do
    api
    |> pick([:requests, :p50_ms, :p95_ms, :max_ms, :avg_ttft_ms, :refusals, :retries])
    |> Map.merge(%{
      requests: Map.get(api, "requests") || 0,
      refusals: Map.get(api, "refusals") || 0,
      retries: Map.get(api, "retries") || 0,
      errors: picks(api["errors"], [:error, :status, :attempt])
    })
  end

  defp timing_view(timing) do
    for {key, field} <- [
          queue: :queue_ms,
          setup: :setup_ms,
          gates: :gates_ms,
          api: :api_ms,
          tools: :tools_ms,
          wall: :wall_ms
        ],
        into: %{},
        do: {field, timing[Atom.to_string(key)]}
  end

  defp extras_view(extras) do
    %{
      active_seconds: extras["active_seconds"],
      mcp: picks(extras["mcp"], [:transport, :scope, :status, :duration_ms]),
      mcp_failures: Map.get(extras, "mcp_failures") || 0,
      decisions: picks(extras["decisions"], [:source, :decision, :count]),
      subagents: picks(extras["subagents"], [:agent_type, :count]),
      by_query_source: picks(extras["by_query_source"], [:source, :requests, :cost_usd])
    }
  end

  # The string-keyed `keys` of a kept map, as atoms.
  defp pick(map, keys), do: Map.new(keys, &{&1, map[Atom.to_string(&1)]})

  defp picks(nil, _keys), do: []
  defp picks(maps, keys), do: Enum.map(maps, &pick(&1, keys))

  defp zeroed(map), do: Map.new(map, fn {key, value} -> {key, value || 0} end)

  defp tool_view(tool) do
    %{
      name: tool.name,
      calls: tool.calls,
      errors: tool.errors,
      denied: tool.denied,
      total_ms: tool.total_ms,
      avg_ms: if(tool.measured > 0, do: round(tool.total_ms / tool.measured))
    }
  end

  # The calls seen as events, with their time from the OpenTelemetry, and
  # the calls only the OpenTelemetry saw.
  defp job_tools(by_type, by_name) do
    results = Map.new(by_type["tool_result"] || [], &{&1["tool_use_id"], &1})
    measured = by_name["tool_result"] || []
    durations = Map.new(measured, &{&1["tool_use_id"], &1["duration_ms"]})
    uses = Enum.reject(by_type["tool_use"] || [], &is_nil(&1["name"]))
    seen = MapSet.new(uses, & &1["id"])

    from_events =
      for use <- uses do
        outcome = results[use["id"]]

        %{
          name: use["name"],
          error: outcome && outcome["is_error"] == true,
          denied: get_in(outcome || %{}, ["decision", "decision"]) == "reject",
          ms: durations[use["id"]]
        }
      end

    from_telemetry =
      for record <- measured,
          is_binary(record["tool_name"]),
          is_nil(record["tool_use_id"]) or not MapSet.member?(seen, record["tool_use_id"]) do
        %{
          name: record["tool_name"],
          error: record["success"] == false,
          denied: false,
          ms: record["duration_ms"]
        }
      end

    (from_events ++ from_telemetry)
    |> Enum.group_by(& &1.name)
    |> Enum.map(fn {name, calls} ->
      times = calls |> Enum.map(& &1.ms) |> Enum.filter(&is_number/1)

      %{
        name: name,
        calls: length(calls),
        errors: Enum.count(calls, & &1.error),
        denied: Enum.count(calls, & &1.denied),
        total_ms: times |> Enum.sum() |> round(),
        measured: length(times)
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
    durations = numbers(requests, "duration_ms")
    ttfts = numbers(requests, "ttft_ms")
    errors = by_name["api_error"] || []

    %{
      "requests" => length(requests),
      "p50_ms" => percentile(durations, 50),
      "p95_ms" => percentile(durations, 95),
      "max_ms" => Enum.max(durations, fn -> nil end),
      "avg_ttft_ms" => average(ttfts),
      "ms_sum" => durations |> Enum.sum() |> round(),
      "ms_count" => length(durations),
      "ttft_sum" => ttfts |> Enum.sum() |> round(),
      "ttft_count" => length(ttfts),
      "errors" =>
        for error <- errors do
          %{
            "error" => error["error"],
            "status" => error["status_code"],
            "attempt" => error["attempt"]
          }
        end,
      "error_count" => length(errors),
      "refusals" => length(by_name["api_refusal"] || []),
      "retries" => length(by_type["api_retry"] || [])
    }
  end

  defp thinking(thoughts) do
    %{
      "count" => length(thoughts),
      "total_ms" => thoughts |> numbers("duration_ms") |> Enum.sum() |> round()
    }
  end

  defp timing(job, tools) do
    %{
      "queue" => queue_ms(job),
      "setup" => rounded(get_in(job.setup || %{}, ["duration_ms"])),
      "gates" => gates_ms(job.gates),
      "api" => job.duration_api_ms,
      "tools" => if(tools == [], do: nil, else: tools |> Enum.map(& &1.total_ms) |> Enum.sum()),
      "wall" => job.wall_ms || job.duration_ms
    }
  end

  defp queue_ms(%Job{inserted_at: %DateTime{} = queued, started_at: %DateTime{} = started}),
    do: max(DateTime.diff(started, queued, :millisecond), 0)

  defp queue_ms(_job), do: nil

  defp gates_ms([_ | _] = gates) do
    case numbers(gates, "duration_ms") do
      [] -> nil
      durations -> durations |> Enum.sum() |> round()
    end
  end

  defp gates_ms(_none), do: nil

  defp extras(job, by_name) do
    connections = Enum.map(by_name["mcp_server_connection"] || [], &connection/1)

    %{
      "active_seconds" => number_or_nil((job.telemetry_totals || %{})["active_seconds"]),
      "mcp" => connections,
      "mcp_failures" => Enum.count(connections, &(&1["status"] not in ["connected", nil])),
      "decisions" => decisions(by_name["tool_decision"] || []),
      "subagents" => subagents(by_name["subagent_completed"] || []),
      "by_query_source" => by_query_source(by_name["api_request"] || [])
    }
  end

  defp connection(record) do
    %{
      "transport" => record["transport_type"],
      "scope" => record["server_scope"] || record["mcp_server_scope"],
      "status" => record["status"],
      "duration_ms" => rounded(record["duration_ms"])
    }
  end

  defp decisions(records) do
    records
    |> Enum.frequencies_by(&{&1["source"] || &1["decision_source"], &1["decision"]})
    |> Enum.map(fn {{source, decision}, count} ->
      %{"source" => source, "decision" => decision, "count" => count}
    end)
    |> Enum.sort_by(&{-&1["count"], &1["source"] || ""})
  end

  defp subagents(records) do
    records
    |> Enum.frequencies_by(& &1["agent_type"])
    |> Enum.map(fn {type, count} -> %{"agent_type" => type, "count" => count} end)
    |> Enum.sort_by(&{-&1["count"], &1["agent_type"] || ""})
  end

  defp by_query_source(requests) do
    requests
    |> Enum.group_by(& &1["query_source"])
    |> Enum.map(fn {source, group} ->
      %{
        "source" => source,
        "requests" => length(group),
        "cost_usd" => group |> numbers("cost_usd") |> Enum.sum()
      }
    end)
    |> Enum.sort_by(&{-&1["requests"], &1["source"] || ""})
  end

  # ── A workspace ───────────────────────────────────────────────────────────

  @doc """
  A workspace's jobs that ended in the last `days`, optionally only a
  `"pipeline"`'s (its name, in `filters`): `tokens` (summed, with how many
  jobs), `cache_hit`, `cost_usd`, `models`, `tools` (calls, failed calls and
  average time), `api` (requests, errors, refusals, retries, average latency
  and time to first token), `denials`, `compactions`, `active_seconds` and
  `mcp_failures`. Read from the jobs' kept summaries.
  """
  @spec workspace(Workspace.t(), pos_integer(), map()) :: %{atom() => term()}
  def workspace(%Workspace{} = workspace, days, filters \\ %{}) do
    since = DateTime.add(DateTime.utc_now(), -days, :day)
    jobs = jobs_query(workspace, since, filters)

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

    summed = summed(jobs)

    %{
      tokens: Map.drop(tokens, [:cost_usd, :denials]),
      cost_usd: tokens.cost_usd,
      cache_hit: Job.cache_hit(tokens.fresh_input, tokens.cache_read, tokens.cache_creation),
      models: models(Repo.all(from j in jobs, select: j.model_usage)),
      tools: workspace_tools(jobs),
      api: %{
        requests: summed.requests,
        avg_ms: ratio(summed.ms_sum, summed.ms_count),
        avg_ttft_ms: ratio(summed.ttft_sum, summed.ttft_count),
        errors: summed.errors,
        refusals: summed.refusals,
        retries: summed.retries
      },
      denials: tokens.denials,
      compactions: summed.compactions,
      active_seconds: summed.active_seconds,
      mcp_failures: summed.mcp_failures
    }
  end

  @doc """
  The query of a workspace's jobs that ended since `since`, optionally only
  a `"pipeline"`'s (its name, in `filters`) or a project's (`"project_id"`).
  """
  @spec jobs_query(Workspace.t(), DateTime.t(), map()) :: Ecto.Query.t()
  def jobs_query(%Workspace{id: workspace_id}, since, filters \\ %{}) do
    query =
      from j in Job,
        where: j.workspace_id == ^workspace_id and j.finished_at >= ^since

    query
    |> by_pipeline(filters["pipeline"])
    |> by_project(filters["project_id"])
  end

  defp by_pipeline(query, name) when is_binary(name) and name != "" do
    from j in query,
      join: r in StageRun,
      on: r.id == j.stage_run_id,
      join: t in Task,
      on: t.id == r.task_id,
      where: t.pipeline_name == ^name
  end

  defp by_pipeline(query, _all), do: query

  defp by_project(query, id) when is_binary(id) and id != "" do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> where(query, [j], j.project_id == ^id)
      :error -> where(query, false)
    end
  end

  defp by_project(query, _all), do: query

  # The kept summaries' counts, added up.
  defp summed(jobs) do
    Repo.one(
      from j in jobs,
        select: %{
          requests: sum(fragment("coalesce((?->'api'->>'requests')::bigint, 0)", j.insights)),
          ms_sum: sum(fragment("coalesce((?->'api'->>'ms_sum')::bigint, 0)", j.insights)),
          ms_count: sum(fragment("coalesce((?->'api'->>'ms_count')::bigint, 0)", j.insights)),
          ttft_sum: sum(fragment("coalesce((?->'api'->>'ttft_sum')::bigint, 0)", j.insights)),
          ttft_count: sum(fragment("coalesce((?->'api'->>'ttft_count')::bigint, 0)", j.insights)),
          errors: sum(fragment("coalesce((?->'api'->>'error_count')::bigint, 0)", j.insights)),
          refusals: sum(fragment("coalesce((?->'api'->>'refusals')::bigint, 0)", j.insights)),
          retries: sum(fragment("coalesce((?->'api'->>'retries')::bigint, 0)", j.insights)),
          compactions: sum(fragment("coalesce((?->>'compactions')::bigint, 0)", j.insights)),
          mcp_failures:
            sum(fragment("coalesce((?->'extras'->>'mcp_failures')::bigint, 0)", j.insights)),
          active_seconds:
            sum(fragment("coalesce((?->>'active_seconds')::numeric, 0)", j.telemetry_totals))
        }
    )
    |> Map.new(fn {key, value} -> {key, decimal_integer(value) || 0} end)
  end

  defp workspace_tools(jobs) do
    Repo.all(
      from s in ToolStat,
        where: s.job_id in subquery(select(jobs, [j], j.id)),
        group_by: s.name,
        select: %{
          name: s.name,
          calls: sum(s.calls),
          errors: sum(s.errors),
          denied: sum(s.denied),
          total_ms: sum(s.total_ms),
          measured: sum(s.measured)
        }
    )
    |> Enum.map(fn tool ->
      %{
        name: tool.name,
        calls: tool.calls,
        errors: tool.errors,
        denied: tool.denied,
        avg_ms: ratio(tool.total_ms, tool.measured)
      }
    end)
    |> Enum.sort_by(&{-&1.calls, &1.name})
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

  defp numbers(maps, key), do: maps |> Enum.map(& &1[key]) |> Enum.filter(&is_number/1)

  defp number_or_nil(value) when is_number(value), do: value
  defp number_or_nil(_value), do: nil

  defp rounded(value) when is_number(value), do: round(value)
  defp rounded(_value), do: nil

  defp average([]), do: nil
  defp average(values), do: round(Enum.sum(values) / length(values))

  defp ratio(_sum, count) when count in [nil, 0], do: nil
  defp ratio(sum, count), do: round(sum / count)

  # Nearest rank: the value below which `p`% of the values fall.
  defp percentile([], _p), do: nil

  defp percentile(values, p) do
    sorted = Enum.sort(values)
    Enum.at(sorted, max(ceil(p / 100 * length(sorted)) - 1, 0))
  end

  defp decimal_integer(nil), do: nil
  defp decimal_integer(%Decimal{} = value), do: value |> Decimal.round(0) |> Decimal.to_integer()
  defp decimal_integer(value) when is_integer(value), do: value
end
