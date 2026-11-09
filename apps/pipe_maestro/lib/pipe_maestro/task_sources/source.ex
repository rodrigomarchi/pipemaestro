defmodule PipeMaestro.TaskSources.Source do
  @moduledoc """
  What a task source does (ADR 0053), registered under its key in
  `PipeMaestro.TaskSources`. A source has four responsibilities:

  1. **receive the trigger**: a webhook (`receive_webhook/4`: checked,
     recorded and processed outside the request) and/or polling (`poll/2`),
     at least one of them;
  2. **read and normalize the item** (`fetch_item/1`,
     `PipeMaestro.TaskSources.Item`), and recognize a link a person pasted
     on a task (`parse_link/1`);
  3. **reflect the work** on the source: each change of one of its tasks
     (`task_changed/1`), how a triage ended without a task
     (`triage_finished/1`), what the runner delivers for it with a stage
     (`runner_delivery/1`) and the line of the pull request that names the
     origin (`pr_reference/1`);
  4. **take replies and commands**: they come in through the trigger and go
     to the same functions as the screen
     (`PipeMaestro.TaskSources.apply_command/3`); `reply/3` answers a person
     on the source.

  The push, the pull request, the commit status and the merge are the git
  host's (`PipeMaestro.Integrations`), not the source's.
  """

  alias PipeMaestro.Jobs.Job
  alias PipeMaestro.Tasks.Task
  alias PipeMaestro.TaskSources.{Item, Origin}

  @doc """
  Takes a webhook delivery. `key` tells which account of the source it is
  for (a git host connection's id), when the source has several.
  """
  @callback receive_webhook(
              key :: String.t() | nil,
              headers :: map(),
              raw_body :: binary(),
              opts :: keyword()
            ) :: {:ok, term()} | :duplicate | {:error, atom()}

  @doc "One pass of the polling, at `now`: what it took in."
  @callback poll(now :: DateTime.t(), opts :: keyword()) :: map()

  @doc "Reads the item of `origin` again on the source."
  @callback fetch_item(Origin.t()) :: {:ok, Item.t()} | {:error, term()}

  @doc "The origin of a link a person pasted, or why the link is none of the source's."
  @callback parse_link(url :: String.t()) :: {:ok, Origin.t()} | {:error, String.t()}

  @doc "Reflects a change of one of the source's tasks on the source."
  @callback task_changed(Task.t()) :: :ok

  @doc "Tells the source how a triage of one of its items ended, when no task came of it."
  @callback triage_finished(Job.t()) :: :ok

  @doc "What the runner delivers for the source with a stage of the task, merged in its delivery."
  @callback runner_delivery(Task.t()) :: map()

  @doc "The line of the task's pull request that names its origin, if any."
  @callback pr_reference(Task.t()) :: String.t() | nil

  @doc "Answers a person on the source, about the item of `origin`."
  @callback reply(Origin.t(), reply_to :: term(), text :: String.t()) :: :ok | {:error, term()}

  @optional_callbacks receive_webhook: 4, poll: 2, parse_link: 1
end
