defmodule PipeMaestro.Integrations.IssueSource do
  @moduledoc """
  The issues of a git host (Forgejo and GitHub) as a task source, under the
  key `"git_issue"` (ADR 0056, `docs/specs/integracoes.md`): the integration
  behind the interface of `PipeMaestro.TaskSources.Source`.

  - **trigger**: the webhooks (`PipeMaestro.Integrations.Ingest`) and the
    reconciliation (`PipeMaestro.Integrations.Reconciler`);
  - **item**: an issue, read with the connection of its linked repository;
    its id is its link, and it keeps its `number`. A link pasted on a task is
    an issue's on any host (`PipeMaestro.Integrations.IssueUrl`);
  - **work**: the feedback on the host (`PipeMaestro.Integrations.Feedback`),
    the commits of the pull request read (`PipeMaestro.Integrations.PrOutcomes`),
    then the merge of the pull request (`PipeMaestro.Integrations.AutoMerge`),
    for a task of a linked repository; the runner comments a decision on the
    issue when it calls the host itself; the pull request closes the issue;
  - **replies and commands**: comments on the issue or the pull request
    (`PipeMaestro.Integrations.Conversation`).
  """
  @behaviour PipeMaestro.TaskSources.Source

  alias PipeMaestro.{Integrations, Repo}

  alias PipeMaestro.Integrations.{
    AutoMerge,
    Connection,
    Credentials,
    Feedback,
    Ingest,
    IssueUrl,
    LinkedRepo,
    PrOutcomes,
    Reconciler
  }

  alias PipeMaestro.Tasks.Task
  alias PipeMaestro.TaskSources.{Item, Origin}

  @key "git_issue"

  @doc "The source's key."
  @spec key() :: String.t()
  def key, do: @key

  @impl true
  def receive_webhook(nil, headers, raw_body, opts),
    do: Ingest.receive_app_webhook(headers, raw_body, opts)

  def receive_webhook(connection_id, headers, raw_body, opts),
    do: Ingest.receive_webhook(connection_id, headers, raw_body, opts)

  @impl true
  def poll(now, opts), do: Reconciler.run(now, opts)

  @impl true
  def fetch_item(%Origin{linked_repo_id: repo_id, ref: %{"number" => number}})
      when is_binary(repo_id) do
    with %LinkedRepo{} = repo <- Repo.get(LinkedRepo, repo_id) || {:error, :not_found},
         %Connection{} = connection <- Repo.get(Connection, repo.connection_id),
         {:ok, client} <- Credentials.client(connection),
         {:ok, issue} <- client.provider.get_issue(client, repo.full_name, number) do
      {:ok, item(repo, issue)}
    end
  end

  def fetch_item(_origin), do: {:error, :not_linked}

  @doc """
  The item of an issue (as a provider reads it) of a linked repository: its
  link is its id, and the task keeps the repository and the number.
  """
  @spec item(LinkedRepo.t(), map()) :: Item.t()
  def item(%LinkedRepo{} = repo, issue) do
    %Item{
      source: @key,
      external_id: issue.url,
      url: issue.url,
      title: issue.title,
      description: issue.body,
      author: issue[:author],
      labels: issue[:labels] || [],
      kind: "Issue",
      ref: %{"number" => issue.number},
      linked_repo_id: repo.id
    }
  end

  @impl true
  def parse_link(url) do
    if Regex.match?(IssueUrl.regex(), url),
      do: {:ok, %Origin{source: @key, external_id: url, url: url}},
      else: {:error, IssueUrl.message()}
  end

  # The feedback runs in the background; with no room for it, the
  # reconciliation writes it later.
  @impl true
  def task_changed(%Task{linked_repo_id: nil}), do: :ok

  def task_changed(%Task{id: task_id}) do
    if Integrations.background(fn -> sync_and_merge(task_id) end) == :busy,
      do: Feedback.mark_dirty(task_id)

    :ok
  end

  defp sync_and_merge(task_id) do
    _synced = Feedback.sync(task_id)
    _observed = PrOutcomes.observe(task_id)
    AutoMerge.check(task_id)
  end

  @impl true
  def triage_finished(job), do: Feedback.triage_finished(job)

  @impl true
  def runner_delivery(%Task{source_url: url, pending_source_note: note})
      when is_binary(url) and is_binary(note),
      do: %{"issue_comment" => %{"url" => url, "body" => note}}

  def runner_delivery(_task), do: %{}

  @impl true
  def pr_reference(%Task{source_url: url}) when is_binary(url), do: "Closes #{url}"
  def pr_reference(_task), do: nil

  @impl true
  def reply(%Origin{linked_repo_id: repo_id, ref: %{"number" => number}}, _reply_to, text)
      when is_binary(repo_id) do
    with %LinkedRepo{} = repo <- Repo.get(LinkedRepo, repo_id) || {:error, :not_found},
         %Connection{} = connection <- Repo.get(Connection, repo.connection_id),
         {:ok, client} <- Credentials.client(connection),
         {:ok, _id} <- client.provider.create_comment(client, repo.full_name, number, text) do
      :ok
    end
  end

  def reply(_origin, _reply_to, _text), do: {:error, :not_linked}
end
