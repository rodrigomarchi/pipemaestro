defmodule PipeMaestro.Jobs.SessionTotals do
  @moduledoc """
  The cost of a run that resumed an earlier session, its own.

  The CLI reports the cost (`total_cost_usd`) and the usage by model
  (`modelUsage`) of the whole session: a run that resumes one (a stage with
  `context: "continue"`, ADR 0041) reports what the runs before it spent
  too, and a task summing its jobs would count them again. Its tokens
  (`usage`) are the run's own.

  What the CLI reported is kept as it came in the job's `session_totals`;
  the job's `cost_usd` and `model_usage` become that minus what the job it
  resumed reported (that job's `session_totals`, or its cost and usage for a
  job from before they were kept).
  """
  import Ecto.Query

  alias PipeMaestro.Jobs.Job
  alias PipeMaestro.Repo

  @doc """
  The end of `job`, as the runner reported it (`attrs`), with its cost and
  usage by model its own and the session's in `"session_totals"`.
  """
  @spec own(Job.t(), map()) :: map()
  def own(%Job{} = job, attrs) do
    reported = %{"cost_usd" => attrs["cost_usd"], "model_usage" => attrs["model_usage"]}
    attrs = Map.put(attrs, "session_totals", reported)

    case resumed(job, attrs) do
      nil ->
        attrs

      before ->
        earlier =
          before.session_totals ||
            %{"cost_usd" => before.cost_usd, "model_usage" => before.model_usage}

        attrs
        |> Map.put("cost_usd", minus(reported["cost_usd"], earlier["cost_usd"]))
        |> Map.put("model_usage", minus_usage(reported["model_usage"], earlier["model_usage"]))
    end
  end

  # The job whose session this run resumed: the latest one of the workspace
  # that ended with that session. A run that fell back to a new session
  # resumed nothing.
  defp resumed(%Job{context: %{"resume_session_id" => session}} = job, %{
         "session_resumed" => true
       })
       when is_binary(session) do
    Repo.one(
      from j in Job,
        where:
          j.workspace_id == ^job.workspace_id and j.session_id == ^session and j.id != ^job.id and
            not is_nil(j.finished_at),
        order_by: [desc: j.finished_at],
        limit: 1
    )
  end

  defp resumed(_job, _attrs), do: nil

  defp minus(nil, _earlier), do: nil
  defp minus(total, nil), do: total

  defp minus(total, earlier) do
    with {:ok, total} <- Decimal.cast(total),
         {:ok, earlier} <- Decimal.cast(earlier) do
      total |> Decimal.sub(earlier) |> Decimal.max(Decimal.new(0))
    else
      :error -> total
    end
  end

  # Each model's tokens and cost, less what the earlier run reported for it.
  defp minus_usage(%{} = total, %{} = earlier) do
    Map.new(total, fn {model, usage} ->
      {model, minus_model(usage, Map.get(earlier, model))}
    end)
  end

  defp minus_usage(total, _earlier), do: total

  defp minus_model(%{} = usage, %{} = earlier) do
    Map.new(usage, fn
      {"cost_usd", cost} -> {"cost_usd", cost |> minus(earlier["cost_usd"]) |> to_number()}
      {key, n} when is_integer(n) -> {key, max(n - (earlier[key] || 0), 0)}
      other -> other
    end)
  end

  defp minus_model(usage, _earlier), do: usage

  defp to_number(%Decimal{} = d), do: Decimal.to_float(d)
  defp to_number(other), do: other
end
