defmodule PipeMaestro.Integrations.Forgejo do
  @moduledoc """
  The Forgejo provider (also Gitea's API, which Forgejo keeps): its webhooks
  and its REST API under `/api/v1`.

  - A delivery is signed in `X-Forgejo-Signature`, the HMAC-SHA256 of the
    raw body in plain hex, and named in `X-Forgejo-Event-Type`, which tells
    `issue_label` from `issues`.
  - A label change arrives as `label_updated` with the issue's whole list of
    labels; telling the one just added is the caller's job
    (`PipeMaestro.Integrations.IssueState`).
  - A draft pull request is a title starting with `"WIP: "`.
  - Lists page by `page` and `limit`; every list here reads at most
    `@max_pages` pages.
  """

  @behaviour PipeMaestro.Integrations.Provider

  alias PipeMaestro.Integrations.{Client, Event}

  @draft "WIP: "
  @max_pages 10
  @page_size 50
  @webhook_events ~w(issues issue_comment pull_request pull_request_review)

  @doc "A client of the instance at `base_url`, sending `authorization`."
  @spec client(String.t(), String.t() | nil) :: Client.t()
  def client(base_url, authorization),
    do: Client.new(__MODULE__, base_url, base_url <> "/api/v1", authorization)

  @doc "The events the platform's webhook subscribes to."
  @spec webhook_events() :: [String.t()]
  def webhook_events, do: @webhook_events

  @impl true
  def verify_signature(headers, raw_body, secret) do
    case headers["x-forgejo-signature"] do
      signature when is_binary(signature) and signature != "" ->
        expected = :crypto.mac(:hmac, :sha256, secret, raw_body) |> Base.encode16(case: :lower)

        byte_size(signature) == byte_size(expected) and
          :crypto.hash_equals(String.downcase(signature), expected)

      _none ->
        false
    end
  end

  @impl true
  def delivery_id(headers), do: headers["x-forgejo-delivery"]

  @impl true
  def parse_event(headers, payload) do
    type = headers["x-forgejo-event-type"] || headers["x-forgejo-event"]
    event(type, payload["action"], payload, headers)
  end

  defp event("issues", "opened", payload, headers),
    do: {:ok, build(:issue_opened, payload, headers)}

  defp event("issues", "closed", payload, headers),
    do: {:ok, build(:issue_closed, payload, headers)}

  defp event("issue_label", _action, payload, headers),
    do: {:ok, build(:issue_labels_changed, payload, headers)}

  defp event(type, "created", payload, headers)
       when type in ["issue_comment", "pull_request_comment"] do
    comment = payload["comment"] || %{}

    event =
      build(:issue_comment, payload, headers)
      |> Map.put(:comment, %{
        id: comment["id"],
        body: comment["body"] || "",
        author: get_in(comment, ["user", "login"])
      })

    {:ok, event}
  end

  defp event("pull_request_review_" <> state, _action, payload, headers)
       when state in ["approved", "rejected"] do
    event =
      build(:pr_review, payload, headers)
      |> Map.put(:review, %{
        state: if(state == "approved", do: :approved, else: :rejected),
        body: get_in(payload, ["review", "content"]) || ""
      })

    {:ok, event}
  end

  defp event("pull_request", "closed", payload, headers),
    do: {:ok, build(:pr_closed, payload, headers)}

  defp event(type, action, _payload, _headers),
    do: {:ignore, "evento sem uso: " <> Enum.join(Enum.reject([type, action], &is_nil/1), " ")}

  defp build(kind, payload, headers) do
    pr = payload["pull_request"]

    %Event{
      kind: kind,
      external_id: delivery_id(headers),
      event: headers["x-forgejo-event-type"] || headers["x-forgejo-event"],
      action: payload["action"],
      repo: payload |> get_in(["repository", "full_name"]) |> downcase(),
      issue: payload["issue"] && issue(payload["issue"]),
      pr: pr && pull(pr),
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
      is_pull: issue["pull_request"] != nil
    }
  end

  defp pull(pr) do
    title = pr["title"] || ""

    %{
      number: pr["number"],
      title: title,
      body: pr["body"] || "",
      url: pr["html_url"],
      head: get_in(pr, ["head", "ref"]),
      merged: pr["merged"] == true,
      draft: String.starts_with?(title, @draft)
    }
  end

  @impl true
  def whoami(client) do
    with {:ok, user, _} <- Client.request(client, url: "/user"),
         do: {:ok, %{login: user["login"], id: user["id"]}}
  end

  @impl true
  def version(client) do
    with {:ok, body, _} <- Client.request(client, url: "/version"), do: {:ok, body["version"]}
  end

  @impl true
  def list_repos(client, query, page, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    with {:ok, body, response} <-
           Client.request(client,
             url: "/repos/search",
             params: [q: query, page: page, limit: limit]
           ) do
      repos = Enum.map(body["data"] || [], &repo/1)
      {:ok, repos, page * limit < total(response, length(repos))}
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

  defp permission(permission) when permission in ["owner", "admin"], do: :admin
  defp permission("write"), do: :write
  defp permission("read"), do: :read
  defp permission(_none), do: :none

  @impl true
  def ensure_labels(client, full_name, labels) do
    with {:ok, existing} <- all_pages(client, "/repos/#{full_name}/labels", []) do
      names = MapSet.new(existing, & &1["name"])

      labels
      |> Enum.reject(&MapSet.member?(names, &1.name))
      |> each_ok(&create_label(client, full_name, &1))
    end
  end

  defp create_label(client, full_name, label) do
    body = %{
      name: label.name,
      color: "#" <> String.trim_leading(label.color, "#"),
      description: label.description
    }

    request_ok(client, method: :post, url: "/repos/#{full_name}/labels", json: body)
  end

  @impl true
  def get_issue(client, full_name, number) do
    with {:ok, body, _} <- Client.request(client, url: "/repos/#{full_name}/issues/#{number}"),
         do: {:ok, issue(body)}
  end

  @impl true
  def list_issues(client, full_name, opts) do
    params =
      [state: "open", type: "issues"]
      |> put_param(:since, opts[:since] && DateTime.to_iso8601(opts[:since]))
      |> put_param(:labels, opts[:labels] && Enum.join(opts[:labels], ","))

    with {:ok, issues} <-
           all_pages(
             client,
             "/repos/#{full_name}/issues",
             params,
             Keyword.get(opts, :page_size, @page_size)
           ),
         do: {:ok, Enum.map(issues, &issue/1)}
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
  def update_comment(client, full_name, id, body) do
    with {:ok, _, _} <-
           Client.request(client,
             method: :patch,
             url: "/repos/#{full_name}/issues/comments/#{id}",
             json: %{body: body}
           ),
         do: :ok
  end

  @impl true
  def add_reaction(client, full_name, target, content) do
    path =
      case target do
        {:issue, number} -> "/repos/#{full_name}/issues/#{number}/reactions"
        {:comment, id} -> "/repos/#{full_name}/issues/comments/#{id}/reactions"
      end

    with {:ok, _, _} <-
           Client.request(client, method: :post, url: path, json: %{content: content}),
         do: :ok
  end

  @impl true
  def set_labels(client, full_name, number, changes) do
    add = Keyword.get(changes, :add, [])
    path = "/repos/#{full_name}/issues/#{number}/labels"

    with :ok <- add_labels(client, path, add) do
      each_ok(Keyword.get(changes, :remove, []), &remove_label(client, path, &1))
    end
  end

  defp add_labels(_client, _path, []), do: :ok

  defp add_labels(client, path, names),
    do: request_ok(client, method: :post, url: path, json: %{labels: names})

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

  # Runs `fun` on each item until one fails.
  defp each_ok(items, fun) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      case fun.(item) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  @impl true
  def create_webhook(client, full_name, url, secret) do
    body = %{
      type: "forgejo",
      active: true,
      events: @webhook_events,
      config: %{url: url, content_type: "json", secret: secret}
    }

    with {:ok, hook, _} <-
           Client.request(client, method: :post, url: "/repos/#{full_name}/hooks", json: body),
         do: {:ok, to_string(hook["id"])}
  end

  @impl true
  def update_webhook(client, full_name, id, url, secret) do
    request_ok(client,
      method: :patch,
      url: "/repos/#{full_name}/hooks/#{id}",
      json: %{active: true, config: %{url: url, content_type: "json", secret: secret}}
    )
  end

  @impl true
  def delete_webhook(client, full_name, id) do
    case Client.request(client, method: :delete, url: "/repos/#{full_name}/hooks/#{id}") do
      {:ok, _, _} -> :ok
      {:error, %{status: 404}} -> :ok
      {:error, _} = error -> error
    end
  end

  @impl true
  def set_commit_status(client, full_name, sha, status) do
    request_ok(client,
      method: :post,
      url: "/repos/#{full_name}/statuses/#{sha}",
      json: Map.take(status, [:state, :context, :description, :target_url])
    )
  end

  @impl true
  def find_open_pr(client, full_name, branch) do
    with {:ok, pulls} <- all_pages(client, "/repos/#{full_name}/pulls", state: "open") do
      {:ok,
       pulls |> Enum.find(&(get_in(&1, ["head", "ref"]) == branch)) |> then(&(&1 && pull(&1)))}
    end
  end

  @impl true
  def create_pr(client, full_name, attrs) do
    title = if attrs[:draft], do: @draft <> attrs.title, else: attrs.title

    with {:ok, pr, _} <-
           Client.request(client,
             method: :post,
             url: "/repos/#{full_name}/pulls",
             json: %{head: attrs.head, base: attrs.base, title: title, body: attrs[:body] || ""}
           ),
         do: {:ok, pull(pr)}
  end

  @impl true
  def update_pr(client, full_name, pr, attrs) do
    changes =
      %{}
      |> then(&if(attrs[:body], do: Map.put(&1, :body, attrs.body), else: &1))
      |> then(fn changes ->
        if attrs[:ready] && pr.draft,
          do: Map.put(changes, :title, String.replace_prefix(pr.title, @draft, "")),
          else: changes
      end)

    if changes == %{} do
      {:ok, pr}
    else
      with {:ok, updated, _} <-
             Client.request(client,
               method: :patch,
               url: "/repos/#{full_name}/pulls/#{pr.number}",
               json: changes
             ),
           do: {:ok, pull(updated)}
    end
  end

  defp request_ok(client, options) do
    with {:ok, _, _} <- Client.request(client, options), do: :ok
  end

  defp all_pages(client, path, params, limit \\ @page_size) do
    Enum.reduce_while(1..@max_pages, {:ok, []}, fn page, {:ok, acc} ->
      client
      |> Client.request(url: path, params: params ++ [page: page, limit: limit])
      |> next_page(acc, limit)
    end)
  end

  defp next_page({:ok, items, response}, acc, limit) when is_list(items) do
    acc = acc ++ items
    last? = length(items) < limit or length(acc) >= total(response, length(acc))
    if last?, do: {:halt, {:ok, acc}}, else: {:cont, {:ok, acc}}
  end

  defp next_page({:ok, _other, _response}, acc, _limit), do: {:halt, {:ok, acc}}
  defp next_page({:error, _} = error, _acc, _limit), do: {:halt, error}

  defp total(response, fallback) do
    case Req.Response.get_header(response, "x-total-count") do
      [count | _] -> String.to_integer(count)
      [] -> fallback
    end
  end

  defp put_param(params, _key, nil), do: params
  defp put_param(params, key, value), do: params ++ [{key, value}]

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
