defmodule PipeMaestro.Integrations.Event do
  @moduledoc """
  An event of a git host, the same for every provider
  (`docs/specs/integracoes.md`, section 2):

  - `kind`: `:ping`, `:issue_opened`, `:issue_labels_changed`,
    `:issue_comment`, `:issue_closed`, `:pr_review`, `:pr_closed` or
    `:check_action`;
  - `issue`: `%{number, title, body, url, author, labels, updated_at,
    is_pull}` (labels by name);
  - `comment`: `%{id, body, author}`;
  - `pr`: `%{number, merged, head}`;
  - `review`: `%{state, body}`, `state` being `:approved` or `:rejected`;
  - `check`: `%{head_sha, name, action}`, a button of a check run pressed
    (`:check_action`, GitHub);
  - `sender`: the login of whoever caused it.
  """

  @type kind ::
          :ping
          | :issue_opened
          | :issue_labels_changed
          | :issue_comment
          | :issue_closed
          | :pr_review
          | :pr_closed
          | :check_action

  @type t :: %__MODULE__{
          kind: kind(),
          external_id: String.t() | nil,
          event: String.t() | nil,
          action: String.t() | nil,
          repo: String.t() | nil,
          issue: map() | nil,
          comment: map() | nil,
          pr: map() | nil,
          review: map() | nil,
          check: map() | nil,
          sender: String.t() | nil
        }

  @enforce_keys [:kind]
  defstruct [
    :kind,
    :external_id,
    :event,
    :action,
    :repo,
    :issue,
    :comment,
    :pr,
    :review,
    :check,
    :sender
  ]
end
