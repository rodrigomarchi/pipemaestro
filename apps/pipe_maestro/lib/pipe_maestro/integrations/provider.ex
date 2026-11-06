defmodule PipeMaestro.Integrations.Provider do
  @moduledoc """
  What the platform needs from a git host, the same for every provider
  (`PipeMaestro.Integrations.Forgejo`, `PipeMaestro.Integrations.GitHub`).

  Every call takes a `PipeMaestro.Integrations.Client` and a repository's
  `"owner/name"`, and answers `{:error, %{status: status, message: message}}`
  on a failure (`status` `nil` when the host could not be reached), never
  raising. Issues come back as in `PipeMaestro.Integrations.Event`.
  """

  alias PipeMaestro.Integrations.{Client, Event}

  @type repo :: String.t()
  @type error :: {:error, %{status: pos_integer() | nil, message: String.t()}}
  @type headers :: %{String.t() => String.t()}

  @doc "Whether `raw_body` is signed with `secret`."
  @callback verify_signature(headers(), raw_body :: binary(), secret :: String.t()) :: boolean()

  @doc "The delivery's id."
  @callback delivery_id(headers()) :: String.t() | nil

  @doc "The normalized event, or why it is not one the platform uses."
  @callback parse_event(headers(), payload :: map()) :: {:ok, Event.t()} | {:ignore, String.t()}

  @doc "Who the credential is."
  @callback whoami(Client.t()) :: {:ok, %{login: String.t(), id: term()}} | error()

  @doc "The server's version, when it says."
  @callback version(Client.t()) :: {:ok, String.t() | nil} | error()

  @doc "Repositories the credential reaches, matching `query`, one page."
  @callback list_repos(Client.t(), query :: String.t(), page :: pos_integer()) ::
              {:ok, [map()], more? :: boolean()} | error()

  @doc "A repository: `%{full_name, id, default_branch}`."
  @callback get_repo(Client.t(), repo()) :: {:ok, map()} | error()

  @doc "What `login` may do in the repository."
  @callback permission(Client.t(), repo(), login :: String.t()) ::
              {:ok, :admin | :write | :read | :none} | error()

  @doc "Creates the labels the repository lacks: `%{name, color, description}`."
  @callback ensure_labels(Client.t(), repo(), [map()]) :: :ok | error()

  @doc "An issue."
  @callback get_issue(Client.t(), repo(), number :: pos_integer()) :: {:ok, map()} | error()

  @doc "Open issues updated since `since`, with any of `labels` (all pages)."
  @callback list_issues(Client.t(), repo(), keyword()) :: {:ok, [map()]} | error()

  @doc "Comments on an issue or pull request; answers the comment's id."
  @callback create_comment(Client.t(), repo(), pos_integer(), String.t()) ::
              {:ok, term()} | error()

  @doc "Edits a comment."
  @callback update_comment(Client.t(), repo(), id :: term(), String.t()) :: :ok | error()

  @doc "Reacts to an issue (`{:issue, n}`) or a comment (`{:comment, id}`)."
  @callback add_reaction(Client.t(), repo(), {:issue | :comment, term()}, String.t()) ::
              :ok | error()

  @doc "Adds and removes labels of an issue, by name."
  @callback set_labels(Client.t(), repo(), pos_integer(), add: [String.t()], remove: [String.t()]) ::
              :ok | error()

  @doc "Creates the repository's webhook; answers its id."
  @callback create_webhook(Client.t(), repo(), url :: String.t(), secret :: String.t()) ::
              {:ok, String.t()} | error()

  @doc "Changes the secret of the repository's webhook."
  @callback update_webhook(Client.t(), repo(), id :: String.t(), url :: String.t(), String.t()) ::
              :ok | error()

  @doc "Removes the repository's webhook."
  @callback delete_webhook(Client.t(), repo(), id :: String.t()) :: :ok | error()

  @doc "Sets a commit status: `%{state, context, description, target_url}`."
  @callback set_commit_status(Client.t(), repo(), sha :: String.t(), map()) :: :ok | error()

  @doc "The open pull request whose head is `branch`."
  @callback find_open_pr(Client.t(), repo(), branch :: String.t()) ::
              {:ok, map() | nil} | error()

  @doc "Opens a pull request: `%{head, base, title, body, draft}`."
  @callback create_pr(Client.t(), repo(), map()) :: {:ok, map()} | error()

  @doc "Changes a pull request: `%{body, ready}`, either."
  @callback update_pr(Client.t(), repo(), map(), map()) :: {:ok, map()} | error()
end
