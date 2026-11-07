defmodule PipeMaestro.FakeGitHub do
  @moduledoc """
  GitHub in memory for the tests, answering through `Req.Test` (the stub
  `PipeMaestro.Integrations`), at the addresses `config/test.exs` gives the
  App (`https://api.github.test`, `https://github.test`).

  - `/app/*` takes only the App's JWT, checked against its key;
  - an installation token (`ghs_*`) is handed per installation, with the
    repositories and permissions asked, and opens the repository endpoints;
  - the OAuth code `code-1` signs in `ana`, who sees the installations of
    `user_installations` (id => account) and has the `memberships` roles;
  - per repository it keeps labels, issues, comments, reactions, check runs
    and pull requests; `deliveries` are the App's webhook deliveries.
  """

  import Plug.Conn

  alias Plug.Conn.Query

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
          installations: Keyword.get(opts, :installations, [99]),
          # What the person who signs in sees: installation id => its account.
          user_installations:
            Keyword.get(opts, :user_installations, %{
              99 => %{"type" => "Organization", "login" => "acme"}
            }),
          # The person's role in each organization.
          memberships: Keyword.get(opts, :memberships, %{"acme" => "admin"}),
          repos: repos,
          permissions: Keyword.get(opts, :permissions, %{}),
          tokens: %{},
          deliveries: Keyword.get(opts, :deliveries, []),
          attempts: [],
          ready: [],
          calls: [],
          next_id: 1
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

  @doc "Changes a pull request as a person would on the host."
  @spec edit_pull(pid(), String.t(), pos_integer(), (map() -> map())) :: :ok
  def edit_pull(fake, name, number, fun) do
    edit = &if(&1["number"] == number, do: fun.(&1), else: &1)
    update_repo(fake, name, &Map.update!(&1, :pulls, fn pulls -> Enum.map(pulls, edit) end))
  end

  @doc "Adds a commit status, as a CI would."
  @spec put_status(pid(), String.t(), String.t(), String.t(), String.t()) :: :ok
  def put_status(fake, name, sha, context, state) do
    status = %{"sha" => sha, "context" => context, "state" => state, "description" => state}
    update_repo(fake, name, &Map.update!(&1, :statuses, fn all -> all ++ [status] end))
  end

  @doc "Adds a check run of another app, as a CI would."
  @spec put_check_run(pid(), String.t(), String.t(), String.t(), String.t() | nil) :: :ok
  def put_check_run(fake, name, sha, check, conclusion) do
    run = %{
      "id" => System.unique_integer([:positive]),
      "name" => check,
      "head_sha" => sha,
      "status" => if(conclusion, do: "completed", else: "in_progress"),
      "conclusion" => conclusion,
      "details_url" => "https://github.test/#{name}/actions/runs/1",
      "output" => %{"title" => "#{check} #{conclusion || "rodando"}"}
    }

    update_repo(fake, name, &Map.update!(&1, :check_runs, fn runs -> runs ++ [run] end))
  end

  @doc "The token handed for an installation, with what it was given."
  @spec tokens(pid()) :: [map()]
  def tokens(fake), do: fake |> state() |> Map.fetch!(:tokens) |> Map.values()

  defp new_repo(name, repo) do
    Map.merge(
      %{
        id: :erlang.phash2(name),
        labels: [],
        issues: %{},
        comments: [],
        reactions: [],
        check_runs: [],
        statuses: [],
        pulls: []
      },
      repo
    )
  end

  @doc false
  @spec call(Plug.Conn.t(), pid()) :: Plug.Conn.t()
  def call(conn, fake) do
    conn = conn |> fetch_query_params() |> read_json()

    Agent.update(
      fake,
      &Map.update!(&1, :calls, fn calls -> [{conn.method, conn.request_path} | calls] end)
    )

    route(conn, fake, conn.method, conn.path_info)
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

  defp bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> token
      _none -> nil
    end
  end

  defp app_jwt?(conn) do
    key = Application.fetch_env!(:pipe_maestro, PipeMaestro.Integrations.GitHub)[:private_key]
    jwk = key |> JOSE.JWK.from_pem() |> JOSE.JWK.to_public()

    case bearer(conn) && JOSE.JWT.verify_strict(jwk, ["RS256"], bearer(conn)) do
      {true, %JOSE.JWT{fields: %{"iss" => "Iv1.teste", "exp" => exp}}, _jws} ->
        exp > System.system_time(:second)

      _invalid ->
        false
    end
  end

  defp installation_token(conn, fake), do: state(fake).tokens[bearer(conn)]

  # OAuth (the web side): a person's token.
  defp route(conn, _fake, "POST", ["login", "oauth", "access_token"]) do
    if conn.body_params["code"] == "code-1" and
         conn.body_params["client_secret"] == "segredo-do-cliente",
       do: respond(conn, 200, %{"access_token" => "ghu_pessoa", "token_type" => "bearer"}),
       else: respond(conn, 200, %{"error" => "bad_verification_code"})
  end

  defp route(conn, _fake, "GET", ["user"]) do
    if bearer(conn) == "ghu_pessoa",
      do: respond(conn, 200, %{"login" => "ana", "id" => 8}),
      else: respond(conn, 401, %{"message" => "Bad credentials"})
  end

  defp route(conn, fake, "GET", ["user", "memberships", "orgs", org]) do
    case bearer(conn) == "ghu_pessoa" && state(fake).memberships[org] do
      role when is_binary(role) -> respond(conn, 200, %{"role" => role, "state" => "active"})
      _none -> respond(conn, 404, %{"message" => "Not Found"})
    end
  end

  defp route(conn, fake, "GET", ["user", "installations"]) do
    if bearer(conn) == "ghu_pessoa",
      do:
        respond(conn, 200, %{
          "installations" =>
            Enum.map(state(fake).user_installations, fn {id, account} ->
              %{"id" => id, "account" => account}
            end)
        }),
      else: respond(conn, 401, %{"message" => "Bad credentials"})
  end

  # The App, with its JWT.
  defp route(conn, fake, method, ["app" | rest]) do
    if app_jwt?(conn),
      do: app_route(conn, fake, method, rest),
      else: respond(conn, 401, %{"message" => "A JSON web token could not be decoded"})
  end

  defp route(conn, fake, method, path) do
    case installation_token(conn, fake) do
      nil -> respond(conn, 401, %{"message" => "Bad credentials"})
      token -> repo_route(conn, fake, token, method, path)
    end
  end

  defp app_route(conn, fake, "POST", ["installations", id, "access_tokens"]) do
    id = String.to_integer(id)

    if id in state(fake).installations do
      token = "ghs_#{Agent.get_and_update(fake, &{&1.next_id, %{&1 | next_id: &1.next_id + 1}})}"
      expires = DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601()

      grant = %{
        installation_id: id,
        token: token,
        repository_ids: conn.body_params["repository_ids"],
        permissions: conn.body_params["permissions"]
      }

      Agent.update(fake, &put_in(&1, [:tokens, token], grant))
      respond(conn, 201, %{"token" => token, "expires_at" => expires})
    else
      respond(conn, 404, %{"message" => "Not Found"})
    end
  end

  defp app_route(conn, fake, "GET", ["hook", "deliveries"]),
    do: respond(conn, 200, state(fake).deliveries)

  defp app_route(conn, fake, "POST", ["hook", "deliveries", id, "attempts"]) do
    Agent.update(
      fake,
      &Map.update!(&1, :attempts, fn attempts -> attempts ++ [String.to_integer(id)] end)
    )

    respond(conn, 202, %{})
  end

  defp app_route(conn, _fake, _method, _path), do: respond(conn, 404, %{"message" => "Not Found"})

  defp repo_route(conn, fake, _token, "GET", ["installation", "repositories"]) do
    repos =
      state(fake).repos |> Enum.sort() |> Enum.map(fn {name, repo} -> repo_json(name, repo) end)

    respond(conn, 200, %{"total_count" => length(repos), "repositories" => paged(conn, repos)})
  end

  defp repo_route(conn, fake, token, method, ["repos", owner, name | rest]) do
    full = "#{owner}/#{name}"

    case state(fake).repos[full] do
      nil -> respond(conn, 404, %{"message" => "Not Found"})
      repo -> repo_path(conn, fake, token, full, repo, method, rest)
    end
  end

  defp repo_route(conn, fake, _token, "POST", ["graphql"]) do
    %{"variables" => %{"id" => node_id}} = conn.body_params
    Agent.update(fake, &Map.update!(&1, :ready, fn ready -> ready ++ [node_id] end))

    respond(conn, 200, %{
      "data" => %{"markPullRequestReadyForReview" => %{"pullRequest" => %{"isDraft" => false}}}
    })
  end

  defp repo_route(conn, _fake, _token, _method, _path),
    do: respond(conn, 404, %{"message" => "Not Found"})

  defp repo_path(conn, _fake, _token, full, repo, "GET", []),
    do: respond(conn, 200, repo_json(full, repo))

  defp repo_path(conn, fake, _token, _full, _repo, "GET", ["collaborators", login, "permission"]) do
    case state(fake).permissions[login] do
      nil -> respond(conn, 404, %{"message" => "Not Found"})
      permission -> respond(conn, 200, %{"permission" => permission})
    end
  end

  defp repo_path(conn, _fake, _token, _full, repo, "GET", ["labels"]),
    do: respond(conn, 200, paged(conn, repo.labels))

  defp repo_path(conn, fake, _token, full, _repo, "POST", ["labels"]) do
    update_repo(
      fake,
      full,
      &Map.update!(&1, :labels, fn labels -> labels ++ [conn.body_params] end)
    )

    respond(conn, 201, conn.body_params)
  end

  defp repo_path(conn, _fake, _token, _full, repo, "GET", ["issues"]) do
    since = conn.query_params["since"]

    issues =
      repo.issues
      |> Map.values()
      |> Enum.filter(&(since == nil or &1["updated_at"] >= since))
      |> Enum.sort_by(& &1["number"])

    respond(conn, 200, paged(conn, issues))
  end

  defp repo_path(conn, _fake, _token, _full, repo, "GET", ["issues", number]) do
    case repo.issues[String.to_integer(number)] do
      nil -> respond(conn, 404, %{"message" => "Not Found"})
      issue -> respond(conn, 200, issue)
    end
  end

  defp repo_path(conn, fake, _token, full, _repo, "POST", ["issues", number, "comments"]) do
    comment = %{
      "id" => next_id(fake),
      "issue" => String.to_integer(number),
      "body" => conn.body_params["body"]
    }

    update_repo(fake, full, &Map.update!(&1, :comments, fn comments -> comments ++ [comment] end))
    respond(conn, 201, comment)
  end

  defp repo_path(conn, fake, _token, full, _repo, "PATCH", ["issues", "comments", id]) do
    edit =
      &if(to_string(&1["id"]) == id, do: %{&1 | "body" => conn.body_params["body"]}, else: &1)

    update_repo(
      fake,
      full,
      &Map.update!(&1, :comments, fn comments -> Enum.map(comments, edit) end)
    )

    respond(conn, 200, %{"id" => String.to_integer(id)})
  end

  defp repo_path(conn, fake, _token, full, _repo, "POST", ["issues", number, "reactions"]) do
    update_repo(
      fake,
      full,
      &Map.update!(&1, :reactions, fn r ->
        r ++ [{:issue, String.to_integer(number), conn.body_params["content"]}]
      end)
    )

    respond(conn, 201, %{})
  end

  defp repo_path(conn, fake, _token, full, _repo, "POST", ["issues", "comments", id, "reactions"]) do
    update_repo(
      fake,
      full,
      &Map.update!(&1, :reactions, fn r ->
        r ++ [{:comment, String.to_integer(id), conn.body_params["content"]}]
      end)
    )

    respond(conn, 201, %{})
  end

  defp repo_path(conn, fake, _token, full, _repo, "POST", ["issues", number, "labels"]) do
    number = String.to_integer(number)

    add = fn labels ->
      labels ++
        for(
          name <- conn.body_params["labels"],
          %{"name" => name} not in labels,
          do: %{"name" => name}
        )
    end

    update_repo(fake, full, &update_in(&1, [:issues, number, "labels"], add))
    respond(conn, 200, [])
  end

  defp repo_path(conn, fake, _token, full, _repo, "DELETE", ["issues", number, "labels", name]) do
    name = URI.decode(name)

    update_repo(
      fake,
      full,
      &update_in(&1, [:issues, String.to_integer(number), "labels"], fn labels ->
        Enum.reject(labels, fn l -> l["name"] == name end)
      end)
    )

    respond(conn, 200, [])
  end

  defp repo_path(conn, fake, _token, full, _repo, "POST", ["check-runs"]) do
    run = Map.put(conn.body_params, "id", next_id(fake))
    update_repo(fake, full, &Map.update!(&1, :check_runs, fn runs -> runs ++ [run] end))
    respond(conn, 201, run)
  end

  defp repo_path(conn, _fake, _token, _full, repo, "GET", ["commits", sha, "check-runs"]) do
    name = conn.query_params["check_name"]

    runs =
      Enum.filter(
        repo.check_runs,
        &(&1["head_sha"] == sha and (name == nil or &1["name"] == name))
      )

    respond(conn, 200, %{"total_count" => length(runs), "check_runs" => runs})
  end

  defp repo_path(conn, fake, _token, full, _repo, "PATCH", ["check-runs", id]) do
    edit = &if(to_string(&1["id"]) == id, do: Map.merge(&1, conn.body_params), else: &1)
    update_repo(fake, full, &Map.update!(&1, :check_runs, fn runs -> Enum.map(runs, edit) end))
    respond(conn, 200, %{"id" => id})
  end

  defp repo_path(conn, _fake, _token, full, repo, "GET", ["pulls"]) do
    [_owner, _name] = String.split(full, "/")
    head = conn.query_params["head"]

    open =
      Enum.filter(
        repo.pulls,
        &(&1["state"] == "open" and
            (head == nil or "#{String.split(full, "/") |> hd()}:#{&1["head"]["ref"]}" == head))
      )

    respond(conn, 200, open)
  end

  defp repo_path(conn, fake, _token, full, repo, "POST", ["pulls"]) do
    number = length(repo.pulls) + 1

    pull = %{
      "number" => number,
      "node_id" => "PR_#{number}",
      "state" => "open",
      "draft" => conn.body_params["draft"] == true,
      "title" => conn.body_params["title"],
      "body" => conn.body_params["body"],
      "head" => %{"ref" => conn.body_params["head"]},
      "html_url" => "https://github.test/#{full}/pull/#{number}"
    }

    update_repo(fake, full, &Map.update!(&1, :pulls, fn pulls -> pulls ++ [pull] end))
    respond(conn, 201, pull)
  end

  defp repo_path(conn, fake, _token, full, _repo, "PATCH", ["pulls", number]) do
    number = String.to_integer(number)

    edit =
      &if(&1["number"] == number,
        do: Map.merge(&1, Map.take(conn.body_params, ["body"])),
        else: &1
      )

    update_repo(fake, full, &Map.update!(&1, :pulls, fn pulls -> Enum.map(pulls, edit) end))
    respond(conn, 200, Enum.find(repo(fake, full).pulls, &(&1["number"] == number)))
  end

  defp repo_path(conn, _fake, _token, _full, repo, "GET", ["pulls", number]) do
    case Enum.find(repo.pulls, &(to_string(&1["number"]) == number)) do
      nil ->
        respond(conn, 404, %{"message" => "Not Found"})

      pull ->
        respond(
          conn,
          200,
          pull |> Map.put_new("mergeable", true) |> Map.put_new("merged", false)
        )
    end
  end

  defp repo_path(conn, fake, _token, full, repo, "PUT", ["pulls", number, "merge"]) do
    number = String.to_integer(number)
    pull = Enum.find(repo.pulls, &(&1["number"] == number))

    cond do
      pull["mergeable"] == false ->
        respond(conn, 405, %{"message" => "Pull Request is not mergeable"})

      conn.body_params["sha"] != get_in(pull, ["head", "sha"]) ->
        respond(conn, 409, %{"message" => "Head branch was modified"})

      true ->
        merged =
          &if(&1["number"] == number,
            do:
              Map.merge(&1, %{"merged" => true, "state" => "closed", "merge" => conn.body_params}),
            else: &1
          )

        update_repo(fake, full, &Map.update!(&1, :pulls, fn pulls -> Enum.map(pulls, merged) end))
        respond(conn, 200, %{"merged" => true})
    end
  end

  defp repo_path(conn, _fake, _token, _full, repo, "GET", ["commits", sha, "status"]) do
    statuses =
      repo.statuses
      |> Enum.filter(&(&1["sha"] == sha))
      |> Enum.reverse()
      |> Enum.uniq_by(& &1["context"])

    respond(conn, 200, %{"sha" => sha, "statuses" => statuses})
  end

  defp repo_path(conn, _fake, _token, _full, _repo, _method, _path),
    do: respond(conn, 404, %{"message" => "Not Found"})

  @doc "An issue as the API returns it, from a few fields."
  @spec issue_json(String.t(), map()) :: map()
  def issue_json(full, issue) do
    number = issue["number"]

    Map.merge(
      %{
        "number" => number,
        "title" => "Issue #{number}",
        "body" => "",
        "state" => "open",
        "html_url" => "https://github.test/#{full}/issues/#{number}",
        "user" => %{"login" => "ana"},
        "labels" => [],
        "updated_at" => "2026-11-06T12:00:00Z",
        "created_at" => "2026-11-06T11:00:00Z"
      },
      Map.update(issue, "labels", [], fn labels -> Enum.map(labels, &%{"name" => &1}) end)
    )
  end

  @doc "Adds an issue to a repository."
  @spec put_issue(pid(), String.t(), map()) :: :ok
  def put_issue(fake, full, issue),
    do: update_repo(fake, full, &put_in(&1, [:issues, issue["number"]], issue_json(full, issue)))

  defp repo_json(full, repo),
    do: %{"id" => repo.id, "full_name" => full, "default_branch" => "main"}

  defp paged(conn, items) do
    per_page = String.to_integer(conn.query_params["per_page"] || "30")
    page = String.to_integer(conn.query_params["page"] || "1")
    items |> Enum.drop((page - 1) * per_page) |> Enum.take(per_page)
  end

  defp update_repo(fake, full, fun), do: Agent.update(fake, &update_in(&1, [:repos, full], fun))

  defp next_id(fake),
    do: Agent.get_and_update(fake, &{&1.next_id, %{&1 | next_id: &1.next_id + 1}})

  defp respond(conn, status, body),
    do: conn |> put_resp_content_type("application/json") |> send_resp(status, JSON.encode!(body))
end
