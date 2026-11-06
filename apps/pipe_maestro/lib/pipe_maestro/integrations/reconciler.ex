defmodule PipeMaestro.Integrations.Reconciler do
  @moduledoc """
  What the webhooks missed, every `:every` ms (default five minutes): no git
  host retries a delivery that failed.

  For each active connection that lets the platform call the host
  (`api_mode` `"control_plane"`), and each linked repository with a label or
  a new issue trigger, it reads the issues updated since the repository's
  last sync (`synced_at`, with a margin) and takes each one through the same
  processing as a webhook (`PipeMaestro.Integrations.Ingest`), as a
  `"reconcile"` delivery. The issue's state keeps a trigger from firing twice.
  It also processes again the deliveries that waited for a runner or failed,
  up to `@max_attempts` times in the last day, and the feedback of tasks that
  could not be written on their issue (`PipeMaestro.Integrations.Feedback`).

  Comments are not read back: a command lost costs little to repeat.

  A process on each node of the control plane, like `PipeMaestro.Maintenance`.
  """
  use GenServer

  import Ecto.Query

  alias PipeMaestro.{Integrations, Repo}

  alias PipeMaestro.Integrations.{
    Connection,
    Credentials,
    Delivery,
    Feedback,
    Ingest,
    IssueState,
    LinkedRepo
  }

  @margin_seconds 120
  @max_attempts 5

  @doc "Starts the periodic reconciliation. Options: `:every` (ms)."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  One pass at `now`: answers how many issues it took in and how many
  deliveries it tried again. Options as in `PipeMaestro.Integrations.Ingest`.
  """
  @spec run(DateTime.t(), keyword()) :: %{
          issues: non_neg_integer(),
          retried: non_neg_integer(),
          feedback: non_neg_integer()
        }
  def run(now, opts \\ []) do
    issues =
      from(c in Connection, where: c.status == "active" and c.api_mode == "control_plane")
      |> Repo.all()
      |> Enum.flat_map(&Integrations.list_repos/1)
      |> Enum.map(&sync_repo(&1, now, opts))
      |> Enum.sum()

    feedback = Enum.count(Feedback.dirty_task_ids(), &(Feedback.sync(&1) == :ok))
    %{issues: issues, retried: retry(now, opts), feedback: feedback}
  end

  @doc "Reads the repository's issues updated since its last sync; answers how many it took in."
  @spec sync_repo(LinkedRepo.t(), DateTime.t(), keyword()) :: non_neg_integer()
  def sync_repo(%LinkedRepo{} = repo, now \\ DateTime.utc_now(), opts \\ []) do
    connection = Repo.get!(Connection, repo.connection_id)
    triggers = Enum.filter(repo.triggers, &(&1.enabled and &1.kind in ["label", "opened"]))

    with [_ | _] <- triggers,
         {:ok, client} <- Credentials.client(connection),
         {:ok, issues} <-
           client.provider.list_issues(client, repo.full_name, since: since(repo, now)) do
      taken = Enum.count(issues, &take(connection, client, repo, triggers, &1, opts))

      repo
      |> LinkedRepo.host_changeset(%{synced_at: DateTime.truncate(now, :second)})
      |> Repo.update!()

      taken
    else
      _nothing -> 0
    end
  end

  defp since(%LinkedRepo{synced_at: nil, inserted_at: inserted_at}, _now), do: inserted_at

  defp since(%LinkedRepo{synced_at: synced_at}, _now),
    do: DateTime.add(synced_at, -@margin_seconds)

  # A new issue the webhook missed is one never seen, created after the
  # repository was linked; any other issue goes in with its labels as they are.
  defp take(connection, client, repo, triggers, issue, opts) do
    kind =
      if Enum.any?(triggers, &(&1.kind == "opened")) and unseen?(repo, issue),
        do: :opened,
        else: :labels

    {event_name, payload} = client.provider.synthetic_event(kind, repo.full_name, issue)

    external_id =
      "reconcile:#{repo.full_name}##{issue.number}:#{kind}:#{issue.updated_at && DateTime.to_unix(issue.updated_at)}"

    match?({:ok, _}, Ingest.ingest_event(connection, external_id, event_name, payload, opts))
  end

  defp unseen?(repo, issue) do
    not Repo.exists?(
      from i in IssueState, where: i.repo_id == ^repo.id and i.number == ^issue.number
    ) and
      issue[:created_at] != nil and DateTime.compare(issue.created_at, repo.inserted_at) == :gt
  end

  defp retry(now, opts) do
    since = DateTime.add(now, -86_400)

    from(d in Delivery,
      where: d.status in ["waiting_runner", "failed"] and d.attempts < @max_attempts,
      where: d.inserted_at > ^since,
      order_by: d.inserted_at
    )
    |> Repo.all()
    |> Enum.map(&Ingest.process(&1, opts))
    |> length()
  end

  @impl true
  def init(opts) do
    every = Keyword.get(opts, :every, :timer.minutes(5))
    Process.send_after(self(), :run, every)
    {:ok, %{every: every, opts: opts}}
  end

  @impl true
  def handle_info(:run, state) do
    _taken = run(DateTime.utc_now(), state.opts)
    Process.send_after(self(), :run, state.every)
    {:noreply, state}
  end
end
