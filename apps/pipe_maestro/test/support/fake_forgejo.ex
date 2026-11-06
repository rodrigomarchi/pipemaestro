defmodule PipeMaestro.FakeForgejo do
  @moduledoc """
  A Forgejo in memory for the tests, answering through `Req.Test` (the stub
  `PipeMaestro.Integrations`, see `config/test.exs`).

      fake = FakeForgejo.start(repos: %{"acme/app" => %{}})
      # ... code under test calls https://forge.test/api/v1/...
      FakeForgejo.state(fake).repos["acme/app"].comments

  It knows one token (`"tok"`, the user `pipemaestro-bot`), refuses requests
  without it, and keeps per repository the labels, hooks, issues, comments,
  reactions, statuses and pull requests it was given or got. `fail/3` makes
  the next calls to a path answer an error status. The OAuth endpoint hands
  tokens and refuses a refresh token used twice, as Forgejo does.
  """

  import Plug.Conn

  alias Plug.Conn.Query

  @base "https://forge.test"

  @doc "The fake instance's base URL."
  @spec base_url() :: String.t()
  def base_url, do: @base

  @doc "Starts a fake and stubs the integrations' HTTP with it."
  @spec start(keyword()) :: pid()
  def start(opts \\ []) do
    repos =
      opts
      |> Keyword.get(:repos, %{"acme/app" => %{}})
      |> Map.new(fn {name, repo} -> {name, new_repo(name, repo)} end)

    {:ok, fake} =
      Agent.start_link(fn ->
        %{
          tokens:
            Map.new(
              Keyword.get(opts, :tokens, ["tok"]),
              &{&1, %{"login" => "pipemaestro-bot", "id" => 7}}
            ),
          version: Keyword.get(opts, :version, "17.0.1+gitea-1.22.0"),
          repos: repos,
          permissions: Keyword.get(opts, :permissions, %{}),
          failures: %{},
          calls: [],
          oauth: %{codes: %{"code-1" => true}, refresh: %{}, issued: 0},
          next_id: 1000
        }
      end)

    Req.Test.stub(PipeMaestro.Integrations, &call(&1, fake))
    fake
  end

  @doc "The fake's whole state."
  @spec state(pid()) :: map()
  def state(fake), do: Agent.get(fake, & &1)

  @doc "A repository's state."
  @spec repo(pid(), String.t()) :: map()
  def repo(fake, name), do: state(fake).repos[name]

  @doc "The calls made so far, oldest first, as `{method, path}`."
  @spec calls(pid()) :: [{String.t(), String.t()}]
  def calls(fake), do: fake |> state() |> Map.fetch!(:calls) |> Enum.reverse()

  @doc "Adds an issue to a repository."
  @spec put_issue(pid(), String.t(), map()) :: :ok
  def put_issue(fake, name, issue) do
    Agent.update(fake, fn state ->
      update_in(
        state,
        [:repos, name, :issues],
        &Map.put(&1, issue["number"], issue_json(name, issue))
      )
    end)
  end

  @doc "Changes a pull request as a person would on the host."
  @spec edit_pull(pid(), String.t(), pos_integer(), (map() -> map())) :: :ok
  def edit_pull(fake, name, number, fun) do
    edit = &if(&1["number"] == number, do: fun.(&1), else: &1)

    Agent.update(
      fake,
      &update_in(&1, [:repos, name, :pulls], fn pulls -> Enum.map(pulls, edit) end)
    )
  end

  @doc "Makes the next `times` calls to `method path` answer `status`."
  @spec fail(pid(), {String.t(), String.t()}, pos_integer(), pos_integer()) :: :ok
  def fail(fake, {method, path}, status, times \\ 1_000) do
    Agent.update(fake, &put_in(&1, [:failures, {method, path}], {status, times}))
  end

  @doc "An issue as the API returns it, from a few fields."
  @spec issue_json(String.t(), map()) :: map()
  def issue_json(name, issue) do
    number = issue["number"]

    Map.merge(
      %{
        "id" => 5000 + number,
        "number" => number,
        "title" => "Issue #{number}",
        "body" => "",
        "state" => "open",
        "html_url" => "#{@base}/#{name}/issues/#{number}",
        "user" => %{"login" => "ana"},
        "labels" => [],
        "pull_request" => nil,
        "updated_at" => "2026-11-06T12:00:00Z",
        "created_at" => "2026-11-06T11:00:00Z"
      },
      Map.update(issue, "labels", [], fn labels -> Enum.map(labels, &%{"name" => &1}) end)
    )
  end

  defp new_repo(name, repo) do
    Map.merge(
      %{
        id: :erlang.phash2(name),
        default_branch: "main",
        labels: [],
        hooks: [],
        issues: %{},
        comments: [],
        reactions: [],
        statuses: [],
        pulls: [],
        # By pull request number: its reviews, each with its line comments.
        reviews: %{}
      },
      repo
    )
  end

  @doc false
  @spec call(Plug.Conn.t(), pid()) :: Plug.Conn.t()
  def call(conn, fake) do
    conn = conn |> fetch_query_params() |> read_json()
    path = "/" <> Enum.join(conn.path_info, "/")
    Agent.update(fake, &Map.update!(&1, :calls, fn calls -> [{conn.method, path} | calls] end))

    cond do
      failure = take_failure(fake, conn.method, path) ->
        respond(conn, failure, %{"message" => "falha simulada"})

      conn.path_info == ["login", "oauth", "access_token"] ->
        oauth(conn, fake)

      not authorized?(conn, fake) ->
        respond(conn, 401, %{"message" => "token is required"})

      true ->
        route(conn, fake, conn.method, conn.path_info)
    end
  end

  defp read_json(conn) do
    {:ok, body, conn} = read_body(conn)

    params =
      case get_req_header(conn, "content-type") do
        ["application/json" <> _] -> JSON.decode!(body)
        ["application/x-www-form-urlencoded" <> _] -> Query.decode(body)
        _other -> %{}
      end

    %{conn | body_params: params}
  end

  defp take_failure(fake, method, path) do
    Agent.get_and_update(fake, fn state ->
      case state.failures[{method, path}] do
        {status, 1} -> {status, %{state | failures: Map.delete(state.failures, {method, path})}}
        {status, n} -> {status, put_in(state, [:failures, {method, path}], {status, n - 1})}
        nil -> {nil, state}
      end
    end)
  end

  defp authorized?(conn, fake) do
    case get_req_header(conn, "authorization") do
      ["token " <> token] -> Map.has_key?(state(fake).tokens, token)
      ["Bearer " <> token] -> Map.has_key?(state(fake).tokens, token)
      _none -> false
    end
  end

  defp current_user(conn, fake) do
    ["token " <> token] =
      get_req_header(conn, "authorization") |> Enum.map(&String.replace(&1, "Bearer ", "token "))

    state(fake).tokens[token]
  end

  defp route(conn, fake, "GET", ["api", "v1", "version"]),
    do: respond(conn, 200, %{"version" => state(fake).version})

  defp route(conn, fake, "GET", ["api", "v1", "user"]),
    do: respond(conn, 200, current_user(conn, fake))

  defp route(conn, fake, "GET", ["api", "v1", "repos", "search"]) do
    query = conn.query_params["q"] || ""
    page = String.to_integer(conn.query_params["page"] || "1")
    limit = String.to_integer(conn.query_params["limit"] || "20")

    all =
      state(fake).repos
      |> Enum.filter(fn {name, _repo} -> String.contains?(name, query) end)
      |> Enum.sort()
      |> Enum.map(fn {name, repo} -> repo_json(name, repo) end)

    conn
    |> put_resp_header("x-total-count", to_string(length(all)))
    |> respond(200, %{
      "ok" => true,
      "data" => all |> Enum.drop((page - 1) * limit) |> Enum.take(limit)
    })
  end

  defp route(conn, fake, method, ["api", "v1", "repos", owner, name | rest]) do
    full = "#{owner}/#{name}"

    case state(fake).repos[full] do
      nil -> respond(conn, 404, %{"message" => "repo not found"})
      repo -> repo_route(conn, fake, full, repo, method, rest)
    end
  end

  defp route(conn, _fake, _method, _path), do: respond(conn, 404, %{"message" => "not found"})

  defp repo_route(conn, _fake, full, repo, "GET", []),
    do: respond(conn, 200, repo_json(full, repo))

  defp repo_route(conn, fake, _full, _repo, "GET", ["collaborators", login, "permission"]) do
    case state(fake).permissions[login] do
      nil -> respond(conn, 404, %{"message" => "not a collaborator"})
      permission -> respond(conn, 200, %{"permission" => permission})
    end
  end

  defp repo_route(conn, _fake, _full, repo, "GET", ["labels"]),
    do:
      conn
      |> put_resp_header("x-total-count", to_string(length(repo.labels)))
      |> respond(200, repo.labels)

  defp repo_route(conn, fake, full, _repo, "POST", ["labels"]) do
    label = Map.put(conn.body_params, "id", next_id(fake))
    update_repo(fake, full, &Map.update!(&1, :labels, fn labels -> labels ++ [label] end))
    respond(conn, 201, label)
  end

  defp repo_route(conn, fake, full, _repo, "POST", ["hooks"]) do
    hook = Map.put(conn.body_params, "id", next_id(fake))
    update_repo(fake, full, &Map.update!(&1, :hooks, fn hooks -> hooks ++ [hook] end))
    respond(conn, 201, hook)
  end

  defp repo_route(conn, fake, full, _repo, "PATCH", ["hooks", id]) do
    update_item(
      fake,
      full,
      :hooks,
      &(to_string(&1["id"]) == id),
      &Map.merge(&1, conn.body_params)
    )

    respond(conn, 200, %{"id" => id})
  end

  defp repo_route(conn, fake, full, _repo, "DELETE", ["hooks", id]) do
    update_repo(
      fake,
      full,
      &Map.update!(&1, :hooks, fn hooks ->
        Enum.reject(hooks, fn h -> to_string(h["id"]) == id end)
      end)
    )

    send_resp(conn, 204, "")
  end

  defp repo_route(conn, _fake, _full, repo, "GET", ["issues"]) do
    since = conn.query_params["since"]
    wanted = conn.query_params["labels"]
    page = String.to_integer(conn.query_params["page"] || "1")
    limit = String.to_integer(conn.query_params["limit"] || "30")

    all =
      repo.issues
      |> Map.values()
      |> Enum.filter(&(&1["state"] == "open"))
      |> Enum.filter(&(since == nil or &1["updated_at"] >= since))
      |> Enum.filter(fn issue ->
        wanted in [nil, ""] or
          Enum.any?(String.split(wanted, ","), fn label ->
            label in Enum.map(issue["labels"], & &1["name"])
          end)
      end)
      |> Enum.sort_by(& &1["number"])

    conn
    |> put_resp_header("x-total-count", to_string(length(all)))
    |> respond(200, all |> Enum.drop((page - 1) * limit) |> Enum.take(limit))
  end

  defp repo_route(conn, _fake, _full, repo, "GET", ["issues", number]) do
    case repo.issues[String.to_integer(number)] do
      nil -> respond(conn, 404, %{"message" => "issue not found"})
      issue -> respond(conn, 200, issue)
    end
  end

  defp repo_route(conn, fake, full, _repo, "POST", ["issues", number, "comments"]) do
    comment = %{
      "id" => next_id(fake),
      "issue" => String.to_integer(number),
      "body" => conn.body_params["body"]
    }

    update_repo(fake, full, &Map.update!(&1, :comments, fn comments -> comments ++ [comment] end))
    respond(conn, 201, comment)
  end

  defp repo_route(conn, fake, full, _repo, "PATCH", ["issues", "comments", id]) do
    body = conn.body_params["body"]
    update_item(fake, full, :comments, &(to_string(&1["id"]) == id), &%{&1 | "body" => body})
    respond(conn, 200, %{"id" => String.to_integer(id), "body" => body})
  end

  defp repo_route(conn, fake, full, _repo, "POST", ["issues", "comments", id, "reactions"]) do
    update_repo(
      fake,
      full,
      &Map.update!(&1, :reactions, fn r ->
        r ++ [{:comment, String.to_integer(id), conn.body_params["content"]}]
      end)
    )

    respond(conn, 201, %{"content" => conn.body_params["content"]})
  end

  defp repo_route(conn, fake, full, _repo, "POST", ["issues", number, "reactions"]) do
    update_repo(
      fake,
      full,
      &Map.update!(&1, :reactions, fn r ->
        r ++ [{:issue, String.to_integer(number), conn.body_params["content"]}]
      end)
    )

    respond(conn, 201, %{"content" => conn.body_params["content"]})
  end

  defp repo_route(conn, fake, full, repo, "POST", ["issues", number, "labels"]) do
    number = String.to_integer(number)
    names = conn.body_params["labels"]
    known = Enum.map(repo.labels, & &1["name"])

    if Enum.all?(names, &(&1 in known)) do
      update_repo(
        fake,
        full,
        &update_in(&1, [:issues, number, "labels"], fn labels -> add_names(labels, names) end)
      )

      respond(conn, 200, repo(fake, full).issues[number]["labels"])
    else
      respond(conn, 422, %{"message" => "label does not exist"})
    end
  end

  defp repo_route(conn, fake, full, _repo, "DELETE", ["issues", number, "labels", name]) do
    number = String.to_integer(number)
    name = URI.decode(name)

    update_repo(
      fake,
      full,
      &update_in(&1, [:issues, number, "labels"], fn labels ->
        Enum.reject(labels, fn l -> l["name"] == name end)
      end)
    )

    send_resp(conn, 204, "")
  end

  defp repo_route(conn, fake, full, _repo, "POST", ["statuses", sha]) do
    status = Map.put(conn.body_params, "sha", sha)
    update_repo(fake, full, &Map.update!(&1, :statuses, fn statuses -> statuses ++ [status] end))
    respond(conn, 201, status)
  end

  defp repo_route(conn, _fake, _full, repo, "GET", ["pulls", number, "reviews"]) do
    reviews = Map.get(repo.reviews, String.to_integer(number), [])
    respond(conn, 200, Enum.map(reviews, &Map.delete(&1, "comments")))
  end

  defp repo_route(conn, _fake, _full, repo, "GET", ["pulls", number, "reviews", id, "comments"]) do
    review =
      Enum.find(
        Map.get(repo.reviews, String.to_integer(number), []),
        &(to_string(&1["id"]) == id)
      )

    respond(conn, 200, (review && review["comments"]) || [])
  end

  defp repo_route(conn, _fake, _full, repo, "GET", ["pulls"]) do
    page = String.to_integer(conn.query_params["page"] || "1")
    limit = String.to_integer(conn.query_params["limit"] || "30")
    open = Enum.filter(repo.pulls, &(&1["state"] == "open"))
    respond(conn, 200, open |> Enum.drop((page - 1) * limit) |> Enum.take(limit))
  end

  defp repo_route(conn, fake, full, repo, "POST", ["pulls"]) do
    number = length(repo.pulls) + 1

    pull = %{
      "number" => number,
      "state" => "open",
      "title" => conn.body_params["title"],
      "body" => conn.body_params["body"],
      "head" => %{"ref" => conn.body_params["head"]},
      "base" => %{"ref" => conn.body_params["base"]},
      "html_url" => "#{@base}/#{full}/pulls/#{number}"
    }

    update_repo(fake, full, &Map.update!(&1, :pulls, fn pulls -> pulls ++ [pull] end))
    respond(conn, 201, pull)
  end

  defp repo_route(conn, fake, full, _repo, "PATCH", ["pulls", number]) do
    number = String.to_integer(number)
    changes = Map.take(conn.body_params, ~w(title body))
    update_item(fake, full, :pulls, &(&1["number"] == number), &Map.merge(&1, changes))
    respond(conn, 200, Enum.find(repo(fake, full).pulls, &(&1["number"] == number)))
  end

  defp repo_route(conn, _fake, _full, _repo, _method, _rest),
    do: respond(conn, 404, %{"message" => "not found"})

  defp oauth(conn, fake) do
    reply = Agent.get_and_update(fake, &grant(&1, conn.body_params))

    case reply do
      nil -> respond(conn, 400, %{"error" => "invalid_grant"})
      tokens -> respond(conn, 200, tokens)
    end
  end

  defp grant(state, %{"grant_type" => "authorization_code"} = params) do
    if state.oauth.codes[params["code"]] && params["code_verifier"] not in [nil, ""],
      do: issue_tokens(state),
      else: {nil, state}
  end

  defp grant(state, %{"grant_type" => "refresh_token", "refresh_token" => token}) do
    if state.oauth.refresh[token] == :valid,
      do: issue_tokens(put_in(state, [:oauth, :refresh, token], :used)),
      else: {nil, state}
  end

  defp grant(state, _params), do: {nil, state}

  defp issue_tokens(state) do
    n = state.oauth.issued + 1
    access = "access-#{n}"
    refresh = "refresh-#{n}"

    state =
      state
      |> put_in([:oauth, :issued], n)
      |> put_in([:oauth, :refresh, refresh], :valid)
      |> put_in([:tokens, access], %{"login" => "ana", "id" => 8})

    {%{
       "access_token" => access,
       "refresh_token" => refresh,
       "expires_in" => 3600,
       "token_type" => "bearer"
     }, state}
  end

  defp repo_json(name, repo),
    do: %{
      "id" => repo.id,
      "full_name" => name,
      "default_branch" => repo.default_branch,
      "html_url" => "#{@base}/#{name}"
    }

  defp add_names(labels, names) do
    present = Enum.map(labels, & &1["name"])
    labels ++ for name <- names, name not in present, do: %{"name" => name}
  end

  defp update_item(fake, full, key, match?, change) do
    change_one = &if(match?.(&1), do: change.(&1), else: &1)
    update_repo(fake, full, &Map.update!(&1, key, fn items -> Enum.map(items, change_one) end))
  end

  defp update_repo(fake, full, fun), do: Agent.update(fake, &update_in(&1, [:repos, full], fun))

  defp next_id(fake),
    do: Agent.get_and_update(fake, &{&1.next_id, %{&1 | next_id: &1.next_id + 1}})

  defp respond(conn, status, body) do
    conn |> put_resp_content_type("application/json") |> send_resp(status, JSON.encode!(body))
  end
end
