defmodule PipeMaestroRunner.Test.ForgejoServer do
  @moduledoc """
  A local, private Forgejo API (403 to anyone not signed in) for one
  repository, `acme/app` (default branch `main`), on 127.0.0.1: the version, the repository, open pull requests (list,
  create, edit) and issue comments. Each request is recorded with its
  `authorization` header (`requests/1`); `pulls/1` and `comments/1` read what
  was written.
  """

  @behaviour Plug

  import Plug.Conn

  @doc "Starts serving; returns `%{url: base_url, state: agent}`."
  def start do
    {:ok, state} = Agent.start_link(fn -> %{pulls: [], comments: [], requests: []} end)

    {:ok, server} =
      Bandit.start_link(
        plug: {__MODULE__, state: state},
        ip: {127, 0, 0, 1},
        port: 0,
        startup_log: false
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    %{url: "http://127.0.0.1:#{port}", state: state, server: server}
  end

  def pulls(%{state: state}), do: Agent.get(state, & &1.pulls)
  def comments(%{state: state}), do: Agent.get(state, &Enum.reverse(&1.comments))
  def requests(%{state: state}), do: Agent.get(state, &Enum.reverse(&1.requests))

  # A person (or the agent) edits the pull request outside the platform.
  def edit_pull(%{state: state}, number, changes) do
    Agent.update(state, fn s ->
      pulls =
        Enum.map(s.pulls, fn
          %{number: ^number} = pr -> Map.merge(pr, Map.new(changes))
          pr -> pr
        end)

      %{s | pulls: pulls}
    end)
  end

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, opts) do
    state = opts[:state]
    {:ok, raw, conn} = read_body(conn)
    body = if raw == "", do: %{}, else: JSON.decode!(raw)
    auth = conn |> get_req_header("authorization") |> List.first()

    Agent.update(state, fn s ->
      %{s | requests: [{conn.method, conn.request_path, auth} | s.requests]}
    end)

    # A private instance: nothing answers without signing in.
    if auth,
      do: route(conn, conn.method, conn.path_info, body, state),
      else: json(conn, 403, %{message: "Only signed in user is allowed to call APIs."})
  end

  defp route(conn, "GET", ["api", "v1", "version"], _body, _state),
    do: json(conn, 200, %{version: "15.0.11+gitea-1.22.0"})

  defp route(conn, "GET", ["api", "v1", "repos", "acme", "app"], _body, _state),
    do: json(conn, 200, %{default_branch: "main", full_name: "acme/app"})

  defp route(conn, "GET", ["api", "v1", "repos", "acme", "app", "pulls"], _body, state) do
    conn = fetch_query_params(conn)
    page = String.to_integer(conn.query_params["page"] || "1")
    open = Agent.get(state, fn s -> Enum.filter(s.pulls, &(&1.state == "open")) end)
    json(conn, 200, if(page == 1, do: Enum.map(open, &view/1), else: []))
  end

  defp route(conn, "POST", ["api", "v1", "repos", "acme", "app", "pulls"], body, state) do
    pr =
      Agent.get_and_update(state, fn s ->
        number = length(s.pulls) + 1

        pr = %{
          number: number,
          title: body["title"],
          body: body["body"],
          head: body["head"],
          base: body["base"],
          state: "open"
        }

        {pr, %{s | pulls: s.pulls ++ [pr]}}
      end)

    json(conn, 201, view(pr))
  end

  defp route(conn, "PATCH", ["api", "v1", "repos", "acme", "app", "pulls", number], body, state) do
    number = String.to_integer(number)

    pr =
      Agent.get_and_update(state, fn s ->
        pulls =
          Enum.map(s.pulls, fn
            %{number: ^number} = pr -> %{pr | title: body["title"], body: body["body"]}
            pr -> pr
          end)

        {Enum.find(pulls, &(&1.number == number)), %{s | pulls: pulls}}
      end)

    json(conn, 201, view(pr))
  end

  defp route(
         conn,
         "POST",
         ["api", "v1", "repos", "acme", "app", "issues", n, "comments"],
         body,
         state
       ) do
    Agent.update(state, fn s -> %{s | comments: [{n, body["body"]} | s.comments]} end)
    json(conn, 201, %{id: 1})
  end

  defp route(conn, _method, _path, _body, _state), do: json(conn, 404, %{message: "not found"})

  defp view(pr) do
    %{
      number: pr.number,
      title: pr.title,
      body: pr.body,
      state: pr.state,
      head: %{ref: pr.head},
      base: %{ref: pr.base},
      html_url: "https://forge.test/acme/app/pulls/#{pr.number}"
    }
  end

  defp json(conn, status, data) do
    conn |> put_resp_content_type("application/json") |> send_resp(status, JSON.encode!(data))
  end
end
