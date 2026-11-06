defmodule PipeMaestro.Integrations.GitHub do
  @moduledoc """
  The GitHub provider, through the platform's GitHub App
  (`config :pipe_maestro, PipeMaestro.Integrations.GitHub`: `app_id`,
  `slug`, `client_id`, `client_secret`, `private_key`, `webhook_secret`, and
  `api_url` / `web_url` for another address than github.com).

  - The App authenticates with a JWT (RS256, its private key, `iss` its client
    id) to mint installation tokens of an hour, which may be narrowed to some
    repositories and permissions (`installation_token/2`).
  - A workspace's connection is an installation, confirmed by the person who
    installed it signing in (`user_installations/1`): the `installation_id`
    of the setup URL alone can be forged.
  - The App has a single webhook (`X-Hub-Signature-256`, the App's secret);
    a repository needs none of its own.
  - A stage's progress is a check run; a draft pull request is GitHub's own,
    marked ready through GraphQL.
  """

  @behaviour PipeMaestro.Integrations.Provider

  alias PipeMaestro.Integrations.{Client, Event}

  @api_version "2026-03-10"
  @per_page 100
  @max_pages 10

  @doc "The App's configuration, `nil` when the platform has none."
  @spec config() :: keyword() | nil
  def config, do: Application.get_env(:pipe_maestro, __MODULE__)

  @doc "Whether the platform has a GitHub App."
  @spec enabled?() :: boolean()
  def enabled?, do: config() != nil

  @doc "GitHub's web address."
  @spec web_url() :: String.t()
  def web_url, do: (config() || [])[:web_url] || "https://github.com"

  defp api_url, do: (config() || [])[:api_url] || "https://api.github.com"

  @doc "Where a person installs the App, carrying `state` back."
  @spec install_url(String.t()) :: String.t()
  def install_url(state),
    do:
      "#{web_url()}/apps/#{config()[:slug]}/installations/new?state=#{URI.encode_www_form(state)}"

  @doc "The App's bot login."
  @spec bot_login() :: String.t()
  def bot_login, do: "#{config()[:slug]}[bot]"

  @doc "A client of the API sending `token`."
  @spec client(String.t()) :: Client.t()
  def client(token) do
    Client.new(__MODULE__, web_url(), api_url(), "Bearer " <> token, [
      {"x-github-api-version", @api_version},
      {"accept", "application/vnd.github+json"}
    ])
  end

  @doc "The App's JWT, valid for nine minutes."
  @spec app_jwt() :: String.t()
  def app_jwt do
    now = System.system_time(:second)
    jwk = JOSE.JWK.from_pem(config()[:private_key])
    claims = %{"iat" => now - 60, "exp" => now + 540, "iss" => config()[:client_id]}
    {_meta, token} = jwk |> JOSE.JWT.sign(%{"alg" => "RS256"}, claims) |> JOSE.JWS.compact()
    token
  end

  @doc """
  An installation token: `%{"token", "expires_at"}`. Options narrow it:
  `:repository_ids` and `:permissions`.
  """
  @spec installation_token(String.t() | integer(), keyword()) :: {:ok, map()} | {:error, map()}
  def installation_token(installation_id, opts \\ []) do
    body =
      %{}
      |> then(
        &if(opts[:repository_ids],
          do: Map.put(&1, :repository_ids, opts[:repository_ids]),
          else: &1
        )
      )
      |> then(
        &if(opts[:permissions], do: Map.put(&1, :permissions, opts[:permissions]), else: &1)
      )

    with {:ok, token, _} <-
           Client.request(client(app_jwt()),
             method: :post,
             url: "/app/installations/#{installation_id}/access_tokens",
             json: body
           ),
         do: {:ok, Map.take(token, ["token", "expires_at"])}
  end

  @doc "The installations a person who signed in with `code` reaches."
  @spec user_installations(String.t()) :: {:ok, [String.t()]} | {:error, map()}
  def user_installations(code) do
    web = Client.new(__MODULE__, web_url(), web_url(), nil)
    form = %{client_id: config()[:client_id], client_secret: config()[:client_secret], code: code}

    case Client.request(web, method: :post, url: "/login/oauth/access_token", form: form) do
      {:ok, %{"access_token" => token}, _} ->
        with {:ok, body, _} <-
               Client.request(client(token), url: "/user/installations", params: [per_page: 100]),
             do: {:ok, Enum.map(body["installations"] || [], &to_string(&1["id"]))}

      {:ok, body, _} ->
        {:error, %{status: 401, message: body["error"] || "sem token"}}

      {:error, _} = error ->
        error
    end
  end

  @doc "The App's webhook deliveries that did not succeed, from the last three days."
  @spec failed_deliveries() :: {:ok, [map()]} | {:error, map()}
  def failed_deliveries do
    since = DateTime.utc_now() |> DateTime.add(-3 * 86_400)

    with {:ok, deliveries, _} <-
           Client.request(client(app_jwt()), url: "/app/hook/deliveries", params: [per_page: 100]) do
      {:ok,
       Enum.filter(deliveries, fn delivery ->
         delivery["status"] != "OK" and
           match?(
             {:ok, at, _} when at > since,
             DateTime.from_iso8601(delivery["delivered_at"] || "")
           )
       end)}
    end
  end

  @doc "Asks GitHub to deliver a webhook again."
  @spec redeliver(integer()) :: :ok | {:error, map()}
  def redeliver(id) do
    with {:ok, _, _} <-
           Client.request(client(app_jwt()),
             method: :post,
             url: "/app/hook/deliveries/#{id}/attempts"
           ),
         do: :ok
  end

  ## Webhooks

  @impl true
  def verify_signature(headers, raw_body, secret) do
    expected =
      "sha256=" <> (:crypto.mac(:hmac, :sha256, secret, raw_body) |> Base.encode16(case: :lower))

    case headers["x-hub-signature-256"] do
      signature when is_binary(signature) and byte_size(signature) == byte_size(expected) ->
        :crypto.hash_equals(signature, expected)

      _none ->
        false
    end
  end

  @doc "Whether `raw_body` is signed with the App's webhook secret."
  @spec app_signed?(map(), binary()) :: boolean()
  def app_signed?(headers, raw_body),
    do: verify_signature(headers, raw_body, config()[:webhook_secret])

  @impl true
  def delivery_id(headers), do: headers["x-github-delivery"]

  @impl true
  def event_name(headers), do: headers["x-github-event"]

  @impl true
  def stored_headers(event_name, delivery_id),
    do: %{"x-github-event" => event_name, "x-github-delivery" => delivery_id}

  @impl true
  def synthetic_event(kind, full_name, issue) do
    payload = %{
      "action" => if(kind == :opened, do: "opened", else: "labeled"),
      "repository" => %{"full_name" => full_name},
      "issue" => %{
        "number" => issue.number,
        "title" => issue.title,
        "body" => issue.body,
        "html_url" => issue.url,
        "state" => issue.state,
        "user" => %{"login" => issue.author},
        "labels" => Enum.map(issue.labels, &%{"name" => &1}),
        "updated_at" => issue.updated_at && DateTime.to_iso8601(issue.updated_at)
      }
    }

    {"issues", payload}
  end

  @impl true
  def parse_event(headers, payload),
    do: event(event_name(headers), payload["action"], payload, headers)

  defp event("issues", "opened", payload, headers),
    do: {:ok, build(:issue_opened, payload, headers)}

  defp event("issues", action, payload, headers) when action in ["labeled", "unlabeled"],
    do: {:ok, build(:issue_labels_changed, payload, headers)}

  defp event("issues", "closed", payload, headers),
    do: {:ok, build(:issue_closed, payload, headers)}

  defp event("issue_comment", "created", payload, headers) do
    comment = payload["comment"] || %{}

    {:ok,
     build(:issue_comment, payload, headers)
     |> Map.put(:comment, %{
       id: comment["id"],
       body: comment["body"] || "",
       author: get_in(comment, ["user", "login"])
     })}
  end

  defp event("pull_request_review", "submitted", payload, headers) do
    state =
      case get_in(payload, ["review", "state"]) do
        "changes_requested" -> :rejected
        "approved" -> :approved
        _commented -> nil
      end

    if state,
      do:
        {:ok,
         build(:pr_review, payload, headers)
         |> Map.put(:review, %{state: state, body: get_in(payload, ["review", "body"]) || ""})},
      else: {:ignore, "review só com comentários"}
  end

  defp event("pull_request", "closed", payload, headers),
    do: {:ok, build(:pr_closed, payload, headers)}

  defp event(type, action, _payload, _headers),
    do: {:ignore, "evento sem uso: " <> Enum.join(Enum.reject([type, action], &is_nil/1), " ")}

  defp build(kind, payload, headers) do
    %Event{
      kind: kind,
      external_id: delivery_id(headers),
      event: event_name(headers),
      action: payload["action"],
      repo: payload |> get_in(["repository", "full_name"]) |> downcase(),
      issue: payload["issue"] && issue(payload["issue"]),
      pr: payload["pull_request"] && pull(payload["pull_request"]),
      sender: get_in(payload, ["sender", "login"])
    }
  end

  defp issue(issue) do
    %{
      number: issue["number"],
      title: issue["title"] || "",
      body: issue["body"] || "",
      url: issue["html_url"],
      state: issue["state"],
      author: get_in(issue, ["user", "login"]),
      labels: Enum.map(issue["labels"] || [], & &1["name"]),
      updated_at: datetime(issue["updated_at"]),
      created_at: datetime(issue["created_at"]),
      is_pull: Map.has_key?(issue, "pull_request")
    }
  end

  defp pull(pr) do
    %{
      number: pr["number"],
      node_id: pr["node_id"],
      title: pr["title"] || "",
      body: pr["body"] || "",
      url: pr["html_url"],
      head: get_in(pr, ["head", "ref"]),
      merged: pr["merged"] == true,
      draft: pr["draft"] == true
    }
  end

  ## The API

  @impl true
  def whoami(client) do
    with {:ok, _body, _} <-
           Client.request(client, url: "/installation/repositories", params: [per_page: 1]),
         do: {:ok, %{login: bot_login(), id: config()[:app_id]}}
  end

  @impl true
  def version(_client), do: {:ok, nil}

  @impl true
  def list_repos(client, query, page) do
    with {:ok, body, _} <-
           Client.request(client,
             url: "/installation/repositories",
             params: [per_page: @per_page, page: page]
           ) do
      repos =
        (body["repositories"] || [])
        |> Enum.map(&repo/1)
        |> Enum.filter(&String.contains?(&1.full_name, String.downcase(query)))

      {:ok, repos, page * @per_page < (body["total_count"] || 0)}
    end
  end

  @impl true
  def get_repo(client, full_name) do
    with {:ok, body, _} <- Client.request(client, url: "/repos/#{full_name}"),
         do: {:ok, repo(body)}
  end

  defp repo(body),
    do: %{
      full_name: downcase(body["full_name"]),
      id: body["id"],
      default_branch: body["default_branch"]
    }

  @impl true
  def permission(client, full_name, login) do
    case Client.request(client, url: "/repos/#{full_name}/collaborators/#{login}/permission") do
      {:ok, %{"permission" => permission}, _} -> {:ok, permission(permission)}
      {:error, %{status: status}} when status in [403, 404] -> {:ok, :none}
      {:error, _} = error -> error
    end
  end

  defp permission("admin"), do: :admin
  defp permission(permission) when permission in ["maintain", "write"], do: :write
  defp permission(permission) when permission in ["triage", "read"], do: :read
  defp permission(_none), do: :none

  @impl true
  def ensure_labels(client, full_name, labels) do
    with {:ok, existing} <- all_pages(client, "/repos/#{full_name}/labels", []) do
      names = MapSet.new(existing, & &1["name"])

      labels
      |> Enum.reject(&MapSet.member?(names, &1.name))
      |> each_ok(fn label ->
        body = %{
          name: label.name,
          color: String.trim_leading(label.color, "#"),
          description: label.description
        }

        request_ok(client, method: :post, url: "/repos/#{full_name}/labels", json: body)
      end)
    end
  end

  @impl true
  def get_issue(client, full_name, number) do
    with {:ok, body, _} <- Client.request(client, url: "/repos/#{full_name}/issues/#{number}"),
         do: {:ok, issue(body)}
  end

  @impl true
  def list_issues(client, full_name, opts) do
    params =
      [state: "open"]
      |> then(&if(opts[:since], do: &1 ++ [since: DateTime.to_iso8601(opts[:since])], else: &1))
      |> then(&if(opts[:labels], do: &1 ++ [labels: Enum.join(opts[:labels], ",")], else: &1))

    with {:ok, issues} <- all_pages(client, "/repos/#{full_name}/issues", params) do
      {:ok, issues |> Enum.map(&issue/1) |> Enum.reject(& &1.is_pull)}
    end
  end

  @impl true
  def create_comment(client, full_name, number, body) do
    with {:ok, comment, _} <-
           Client.request(client,
             method: :post,
             url: "/repos/#{full_name}/issues/#{number}/comments",
             json: %{body: body}
           ),
         do: {:ok, comment["id"]}
  end

  @impl true
  def update_comment(client, full_name, id, body),
    do:
      request_ok(client,
        method: :patch,
        url: "/repos/#{full_name}/issues/comments/#{id}",
        json: %{body: body}
      )

  @impl true
  def add_reaction(client, full_name, {:issue, number}, content),
    do:
      request_ok(client,
        method: :post,
        url: "/repos/#{full_name}/issues/#{number}/reactions",
        json: %{content: content}
      )

  def add_reaction(client, full_name, {:comment, id}, content),
    do:
      request_ok(client,
        method: :post,
        url: "/repos/#{full_name}/issues/comments/#{id}/reactions",
        json: %{content: content}
      )

  @impl true
  def set_labels(client, full_name, number, changes) do
    path = "/repos/#{full_name}/issues/#{number}/labels"

    with :ok <- add_labels(client, path, Keyword.get(changes, :add, [])),
         do: each_ok(Keyword.get(changes, :remove, []), &remove_label(client, path, &1))
  end

  defp remove_label(client, path, name) do
    case Client.request(client,
           method: :delete,
           url: path <> "/" <> URI.encode(name, &URI.char_unreserved?/1)
         ) do
      {:ok, _, _} -> :ok
      {:error, %{status: 404}} -> :ok
      {:error, _} = error -> error
    end
  end

  defp add_labels(_client, _path, []), do: :ok

  defp add_labels(client, path, names),
    do: request_ok(client, method: :post, url: path, json: %{labels: names})

  # The App's webhook covers every repository of an installation.
  @impl true
  def create_webhook(_client, _full_name, _url, _secret), do: {:ok, "app"}

  @impl true
  def update_webhook(_client, _full_name, _id, _url, _secret), do: :ok

  @impl true
  def delete_webhook(_client, _full_name, _id), do: :ok

  # A stage's progress is a check run named after it.
  @impl true
  def set_commit_status(client, full_name, sha, status) do
    {run_status, conclusion} =
      case status.state do
        "pending" -> {"in_progress", nil}
        "success" -> {"completed", "success"}
        "failure" -> {"completed", "failure"}
        "warning" -> {"completed", "action_required"}
        _error -> {"completed", "cancelled"}
      end

    body =
      %{
        name: status.context,
        head_sha: sha,
        status: run_status,
        details_url: status[:target_url],
        output: %{title: status.description, summary: status.description}
      }
      |> then(&if(conclusion, do: Map.put(&1, :conclusion, conclusion), else: &1))

    request_ok(client, method: :post, url: "/repos/#{full_name}/check-runs", json: body)
  end

  @impl true
  def find_open_pr(client, full_name, branch) do
    [owner, _name] = String.split(full_name, "/")

    with {:ok, pulls, _} <-
           Client.request(client,
             url: "/repos/#{full_name}/pulls",
             params: [state: "open", head: "#{owner}:#{branch}"]
           ) do
      {:ok,
       pulls |> Enum.find(&(get_in(&1, ["head", "ref"]) == branch)) |> then(&(&1 && pull(&1)))}
    end
  end

  @impl true
  def create_pr(client, full_name, attrs) do
    body = %{
      head: attrs.head,
      base: attrs.base,
      title: attrs.title,
      body: attrs[:body] || "",
      draft: attrs[:draft] == true
    }

    with {:ok, pr, _} <-
           Client.request(client, method: :post, url: "/repos/#{full_name}/pulls", json: body),
         do: {:ok, pull(pr)}
  end

  @impl true
  def update_pr(client, full_name, pr, attrs) do
    with {:ok, pr} <- update_body(client, full_name, pr, attrs[:body]),
         :ok <- mark_ready(client, pr, attrs[:ready]) do
      {:ok, if(attrs[:ready], do: %{pr | draft: false}, else: pr)}
    end
  end

  defp update_body(_client, _full_name, pr, nil), do: {:ok, pr}

  defp update_body(client, full_name, pr, body) do
    with {:ok, updated, _} <-
           Client.request(client,
             method: :patch,
             url: "/repos/#{full_name}/pulls/#{pr.number}",
             json: %{body: body}
           ),
         do: {:ok, pull(updated)}
  end

  defp mark_ready(client, %{draft: true, node_id: node_id}, true) do
    query =
      "mutation($id: ID!) { markPullRequestReadyForReview(input: {pullRequestId: $id}) { pullRequest { isDraft } } }"

    request_ok(client,
      method: :post,
      url: "/graphql",
      json: %{query: query, variables: %{id: node_id}}
    )
  end

  defp mark_ready(_client, _pr, _ready), do: :ok

  defp request_ok(client, options) do
    with {:ok, _, _} <- Client.request(client, options), do: :ok
  end

  defp each_ok(items, fun) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      case fun.(item) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp all_pages(client, path, params) do
    Enum.reduce_while(1..@max_pages, {:ok, []}, fn page, {:ok, acc} ->
      case Client.request(client, url: path, params: params ++ [per_page: @per_page, page: page]) do
        {:ok, items, _} when is_list(items) and length(items) < @per_page ->
          {:halt, {:ok, acc ++ items}}

        {:ok, items, _} when is_list(items) ->
          {:cont, {:ok, acc ++ items}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
  end

  defp datetime(nil), do: nil

  defp datetime(text) do
    case DateTime.from_iso8601(text) do
      {:ok, datetime, _offset} -> DateTime.truncate(datetime, :second)
      _invalid -> nil
    end
  end

  defp downcase(nil), do: nil
  defp downcase(text), do: String.downcase(text)
end
